import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api.dart';

const statusColors = {
  'ok': Colors.green,
  'at_risk': Colors.orange,
  'late': Colors.red,
  'done': Colors.grey,
};
const statusLabels = {'ok': 'A tiempo', 'at_risk': 'En riesgo', 'late': 'Atrasada', 'done': 'Hecha'};

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, required this.api});
  final Api api;
  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late Future<List<dynamic>> _f = _load();

  Future<List<dynamic>> _load() async => [
        await widget.api.get('/events?days=7'),
        await widget.api.get('/plan?days=14'),
      ];

  @override
  Widget build(BuildContext context) {
    final hm = DateFormat('EEE d MMM HH:mm', 'es');
    return Scaffold(
      appBar: AppBar(title: const Text('Hoy y próximos días'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: () => setState(() => _f = _load())),
      ]),
      body: FutureBuilder<List<dynamic>>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${s.error}')));
          final ev = s.data![0] as Map, plan = s.data![1] as Map;
          final late = (plan['statuses'] as List).where((x) => x['status'] == 'late' || x['status'] == 'at_risk');
          return ListView(padding: const EdgeInsets.all(12), children: [
            if (late.isNotEmpty)
              Card(
                color: Colors.red.withOpacity(0.12),
                child: ListTile(
                  leading: const Icon(Icons.warning_amber, color: Colors.red),
                  title: Text('${late.length} tarea(s) en riesgo o atrasadas'),
                  subtitle: const Text('Revisa la pestaña Tareas'),
                ),
              ),
            if ((ev['conflicts'] as List).isNotEmpty)
              Card(
                color: Colors.orange.withOpacity(0.12),
                child: ListTile(
                  leading: const Icon(Icons.event_busy, color: Colors.orange),
                  title: Text('${(ev['conflicts'] as List).length} conflicto(s) de horario'),
                  subtitle: Text((ev['conflicts'] as List)
                      .take(3)
                      .map((x) => '${x['a']} ↔ ${x['b']}')
                      .join('\n')),
                ),
              ),
            const _Header('Eventos (clases, trabajo)'),
            for (final e in ev['events'])
              ListTile(
                dense: true,
                leading: Icon(e['context'] == 'trabajo' ? Icons.work_outline : Icons.school_outlined),
                title: Text(e['title']),
                subtitle: Text('${hm.format(DateTime.parse(e['start']).toLocal())} · ${e['calendar']}'),
              ),
            const _Header('Plan sugerido'),
            for (final b in plan['blocks'])
              ListTile(
                dense: true,
                leading: const Icon(Icons.timer_outlined),
                title: Text(b['title']),
                subtitle: Text('${hm.format(DateTime.parse(b['start']).toLocal())} → ${DateFormat.Hm().format(DateTime.parse(b['end']).toLocal())}'),
              ),
          ]);
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.t);
  final String t;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(t, style: Theme.of(context).textTheme.titleMedium),
      );
}
