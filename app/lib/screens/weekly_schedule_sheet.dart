import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';

const _dayLabels = {
  1: 'Lun',
  2: 'Mar',
  3: 'Mié',
  4: 'Jue',
  5: 'Vie',
  6: 'Sáb',
  7: 'Dom',
};

String formatDays(String daysCsv) {
  final nums = daysCsv
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .toSet();
  if (nums.containsAll([1, 2, 3, 4, 5]) && nums.length == 5) return 'Lun a Vie';
  if (nums.length == 7) return 'Todos los días';
  return [for (final d in [1, 2, 3, 4, 5, 6, 7]) if (nums.contains(d)) _dayLabels[d]!].join(', ');
}

Future<bool?> showWeeklyScheduleModal(BuildContext context, Api api) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.88,
      child: WeeklyScheduleSheet(api: api),
    ),
  );
}

class WeeklyScheduleSheet extends StatefulWidget {
  const WeeklyScheduleSheet({super.key, required this.api});
  final Api api;

  @override
  State<WeeklyScheduleSheet> createState() => _WeeklyScheduleSheetState();
}

class _WeeklyScheduleSheetState extends State<WeeklyScheduleSheet> {
  List<dynamic> _blocks = [];
  bool _loading = true;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.get('/weekly-blocks') as List;
      if (mounted) {
        setState(() {
          _blocks = res;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  TimeOfDay _parseTod(String s) {
    final p = s.split(':');
    return TimeOfDay(hour: int.tryParse(p[0]) ?? 8, minute: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0);
  }

  String _fmtTod(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _openEditor([Map? existing]) async {
    final title = TextEditingController(text: existing?['title']?.toString() ?? 'Jornada laboral');
    final desc = TextEditingController(text: existing?['description']?.toString() ?? '');
    var ctx = existing?['context']?.toString() ?? 'trabajo';
    final selectedDays = <int>{
      for (final p in (existing?['days']?.toString() ?? '1,2,3,4,5').split(','))
        if (int.tryParse(p.trim()) != null) int.parse(p.trim()),
    };
    if (selectedDays.isEmpty) selectedDays.addAll([1, 2, 3, 4, 5]);
    var start = _parseTod(existing?['start_time']?.toString() ?? '08:00');
    var end = _parseTod(existing?['end_time']?.toString() ?? '17:00');

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(existing == null ? 'Añadir bloque semanal' : 'Editar bloque semanal'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(
                      labelText: 'Nombre del bloque (ej. Trabajo, Turno mañana, Clase)',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: ctx,
                    decoration: const InputDecoration(labelText: 'Contexto', prefixIcon: Icon(Icons.category_outlined)),
                    items: const [
                      DropdownMenuItem(value: 'trabajo', child: Text('💼 Trabajo')),
                      DropdownMenuItem(value: 'universidad', child: Text('🎓 Universidad')),
                      DropdownMenuItem(value: 'personal', child: Text('🏠 Personal')),
                    ],
                    onChanged: (v) => set(() => ctx = v!),
                  ),
                  const SizedBox(height: 14),
                  Text('Días de la semana', style: Theme.of(c).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in _dayLabels.entries)
                        FilterChip(
                          label: Text(e.value),
                          selected: selectedDays.contains(e.key),
                          onSelected: (v) => set(() {
                            if (v) {
                              selectedDays.add(e.key);
                            } else if (selectedDays.length > 1) {
                              selectedDays.remove(e.key);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.schedule),
                          label: Text('Inicio: ${_fmtTod(start)}'),
                          onPressed: () async {
                            final t = await showTimePicker(context: c, initialTime: start);
                            if (t != null) set(() => start = t);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.schedule_send),
                          label: Text('Fin: ${_fmtTod(end)}'),
                          onPressed: () async {
                            final t = await showTimePicker(context: c, initialTime: end);
                            if (t != null) set(() => end = t);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: desc,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notas o detalles (opcional)',
                      hintText: 'Ej. Oficina / Remoto / Reuniones de equipo',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );

    if (ok != true || title.text.trim().isEmpty) return;
    final payload = {
      'title': title.text.trim(),
      'context': ctx,
      'days': (selectedDays.toList()..sort()).join(','),
      'start_time': _fmtTod(start),
      'end_time': _fmtTod(end),
      'description': desc.text.trim(),
      'active': existing?['active'] ?? true,
    };
    try {
      if (existing == null) {
        await widget.api.post('/weekly-blocks', payload);
      } else {
        await widget.api.patch('/weekly-blocks/${existing['id']}', payload);
      }
      _changed = true;
      widget.api.invalidateCache();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al guardar horario: $e')));
      }
    }
  }

  Future<void> _addQuickPreset(String title, String days, String start, String end, String desc) async {
    try {
      await widget.api.post('/weekly-blocks', {
        'title': title,
        'context': 'trabajo',
        'days': days,
        'start_time': start,
        'end_time': end,
        'description': desc,
        'active': true,
      });
      _changed = true;
      widget.api.invalidateCache();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context, _changed),
          ),
          title: const Text('Mi horario fijo semanal'),
          actions: [
            FilledButton.tonalIcon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Añadir bloque'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('No se pudo cargar el horario:\n$_error', textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _load, child: const Text('Reintentar')),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.45),
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline, size: 22),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Tu calendario del trabajo en Google Workspace suele mostrar solo "Busy / Ocupado" por políticas de privacidad de la empresa. '
                                  'Añade aquí tus bloques fijos de trabajo o clases: aparecerán con nombre y detalles en tu calendario y el planificador automático respetará esas horas.',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ActionChip(
                            avatar: const Icon(Icons.work_outline, size: 18),
                            label: const Text('+ Lun–Vie 08:00 a 17:00 (Trabajo)'),
                            onPressed: () => _addQuickPreset('Jornada laboral', '1,2,3,4,5', '08:00', '17:00', 'Horario de trabajo'),
                          ),
                          ActionChip(
                            avatar: const Icon(Icons.work_outline, size: 18),
                            label: const Text('+ Lun–Vie 09:00 a 18:00 (Trabajo)'),
                            onPressed: () => _addQuickPreset('Jornada laboral', '1,2,3,4,5', '09:00', '18:00', 'Horario de trabajo'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_blocks.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                            child: Text(
                              'Aún no has añadido bloques a tu horario semanal.\nUsa un botón rápido arriba o pulsa "Añadir bloque".',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      for (final b in _blocks)
                        Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: contextColor(b['context']?.toString()).withOpacity(0.15),
                              child: Icon(
                                b['context'] == 'universidad'
                                    ? Icons.school_outlined
                                    : b['context'] == 'trabajo'
                                        ? Icons.work_outline
                                        : Icons.person_outline,
                                color: contextColor(b['context']?.toString()),
                              ),
                            ),
                            title: Text(
                              b['title'].toString(),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                decoration: b['active'] == true ? null : TextDecoration.lineThrough,
                              ),
                            ),
                            subtitle: Text(
                              '${formatDays(b['days'].toString())} · ${b['start_time']} – ${b['end_time']}'
                              '${(b['description'] ?? '').toString().isNotEmpty ? '\n${b['description']}' : ''}',
                            ),
                            isThreeLine: (b['description'] ?? '').toString().isNotEmpty,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: b['active'] == true,
                                  onChanged: (v) async {
                                    await widget.api.patch('/weekly-blocks/${b['id']}', {'active': v});
                                    _changed = true;
                                    widget.api.invalidateCache();
                                    _load();
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Editar',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _openEditor(b as Map),
                                ),
                                IconButton(
                                  tooltip: 'Eliminar',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    await widget.api.delete('/weekly-blocks/${b['id']}');
                                    _changed = true;
                                    widget.api.invalidateCache();
                                    _load();
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}
