import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api.dart';
import 'today_screen.dart' show statusColors, statusLabels;

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.api});
  final Api api;
  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  late Future<List<dynamic>> _f = _load();
  int? _timerTask;
  DateTime? _timerStart;
  Timer? _tick;

  Future<List<dynamic>> _load() async => [
        await widget.api.get('/tasks'),
        await widget.api.get('/plan?days=30'),
      ];

  void _refresh() => setState(() => _f = _load());

  void _toggleTimer(int id) async {
    if (_timerTask == id) {
      final mins = DateTime.now().difference(_timerStart!).inMinutes.clamp(1, 1000);
      _tick?.cancel();
      setState(() => _timerTask = null);
      await widget.api.post('/tasks/$id/log', {'minutes': mins});
      _refresh();
    } else {
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
      setState(() {
        _timerTask = id;
        _timerStart = DateTime.now();
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _add() async {
    final title = TextEditingController();
    final est = TextEditingController(text: '60');
    var ctx = 'universidad';
    var prio = 2;
    var deadline = DateTime.now().add(const Duration(days: 2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Nueva tarea'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Título'), autofocus: true),
              TextField(controller: est, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Estimación (min)')),
              DropdownButtonFormField<String>(
                value: ctx,
                items: const ['universidad', 'trabajo', 'personal'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => set(() => ctx = v!),
              ),
              DropdownButtonFormField<int>(
                value: prio,
                items: const [DropdownMenuItem(value: 1, child: Text('Prioridad baja')), DropdownMenuItem(value: 2, child: Text('Prioridad media')), DropdownMenuItem(value: 3, child: Text('Prioridad alta'))],
                onChanged: (v) => set(() => prio = v!),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Entrega: ${DateFormat('d MMM HH:mm', 'es').format(deadline)}'),
                trailing: const Icon(Icons.edit_calendar),
                onTap: () async {
                  final d = await showDatePicker(context: c, initialDate: deadline, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
                  if (d == null || !c.mounted) return;
                  final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(deadline));
                  set(() => deadline = DateTime(d.year, d.month, d.day, t?.hour ?? 23, t?.minute ?? 59));
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await widget.api.post('/tasks', {
        'title': title.text.trim(),
        'context': ctx,
        'estimate_min': int.tryParse(est.text) ?? 60,
        'priority': prio,
        'deadline': deadline.toIso8601String(), // hora local sin zona: el servidor asume su zona
      });
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tareas'), actions: [
          IconButton(
            tooltip: 'Importar entregas de Canvas',
            icon: const Icon(Icons.download),
            onPressed: () async {
              final cals = await widget.api.get('/calendars') as List;
              var n = 0;
              for (final c in cals.where((c) => c['context'] == 'universidad')) {
                n += (await widget.api.post('/calendars/${c['id']}/import-tasks'))['imported'] as int;
              }
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n tareas importadas')));
              _refresh();
            },
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
        body: FutureBuilder<List<dynamic>>(
          future: _f,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${s.error}')));
            final tasks = s.data![0] as List;
            final st = {for (final x in s.data![1]['statuses'] as List) x['task_id']: x};
            if (tasks.isEmpty) return const Center(child: Text('Sin tareas pendientes 🎉'));
            return ListView(children: [
              for (final t in tasks)
                Builder(builder: (c) {
                  final status = st[t['id']]?['status'] ?? 'ok';
                  final running = _timerTask == t['id'];
                  final el = running ? DateTime.now().difference(_timerStart!).inMinutes : 0;
                  return ListTile(
                    leading: Checkbox(
                      value: false,
                      onChanged: (_) async {
                        await widget.api.patch('/tasks/${t['id']}', {'done': true});
                        _refresh();
                      },
                    ),
                    title: Text(t['title']),
                    subtitle: Text('${t['context']} · ${t['logged_min']}/${t['estimate_min']} min · vence ${DateFormat('d MMM HH:mm', 'es').format(DateTime.parse(t['deadline']).toLocal())}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Chip(label: Text(statusLabels[status] ?? status), backgroundColor: (statusColors[status] ?? Colors.grey).withOpacity(0.2)),
                      IconButton(
                        tooltip: running ? 'Detener ($el min)' : 'Iniciar cronómetro',
                        icon: Icon(running ? Icons.stop_circle : Icons.play_circle_outline, color: running ? Colors.red : null),
                        onPressed: () => _toggleTimer(t['id']),
                      ),
                    ]),
                  );
                }),
            ]);
          },
        ),
      );
}
