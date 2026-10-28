import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';

Future<void> showStatsModal(BuildContext context, Api api) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: StatsSheet(api: api),
    ),
  );
}

class StatsSheet extends StatefulWidget {
  const StatsSheet({super.key, required this.api});
  final Api api;

  @override
  State<StatsSheet> createState() => _StatsSheetState();
}

class _StatsSheetState extends State<StatsSheet> {
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _tasks = [];
  bool _syncing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    final cachedStats = widget.api.peekCache('/stats');
    if (cachedStats is Map) {
      _stats = Map<String, dynamic>.from(cachedStats);
    }
    final cachedBundle = widget.api.peekCache('bundle');
    if (cachedBundle is Map && cachedBundle['tasks'] is List) {
      _tasks = [for (final t in cachedBundle['tasks'] as List) Map<String, dynamic>.from(t as Map)];
    }
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      final res = await widget.api.get('/stats') as Map;
      if (!mounted) return;
      setState(() {
        _stats = Map<String, dynamic>.from(res);
        _syncing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _syncing = false;
        if (_stats == null) _error = '$e';
      });
    }
  }

  String _fmtMin(int mins) {
    if (mins <= 0) return '0 min';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final byCtxRaw = (_stats?['minutes_by_context'] as List?) ?? const [];
    final ctxMap = <String, int>{'universidad': 0, 'trabajo': 0, 'personal': 0};
    for (final row in byCtxRaw) {
      if (row is Map) {
        final k = (row['context'] ?? 'personal').toString();
        ctxMap[k] = (ctxMap[k] ?? 0) + ((row['minutes'] as num?)?.toInt() ?? 0);
      }
    }
    // Si aún no hay respuesta de /stats pero tenemos tareas en caché, calculamos desde las tareas locales
    if (byCtxRaw.isEmpty && _tasks.isNotEmpty) {
      for (final t in _tasks) {
        final k = (t['context'] ?? 'personal').toString();
        ctxMap[k] = (ctxMap[k] ?? 0) + ((t['logged_min'] as num?)?.toInt() ?? 0);
      }
    }

    final totalMin = ctxMap.values.fold<int>(0, (a, b) => a + b);
    final ratio = (_stats?['estimate_accuracy_ratio'] as num?)?.toDouble();
    final overdue = (_stats?['overdue_tasks'] as num?)?.toInt() ??
        _tasks.where((t) => t['done'] != true && DateTime.parse(t['deadline'].toString()).isBefore(DateTime.now())).length;
    final doneTasks = _tasks.where((t) => t['done'] == true).toList();
    final pendingTasks = _tasks.where((t) => t['done'] != true).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Estadísticas y Productividad'),
        actions: [
          IconButton(
            tooltip: 'Actualizar estadísticas',
            icon: const Icon(Icons.refresh),
            onPressed: _fetch,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
        bottom: _syncing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _error != null && _stats == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _fetch, child: const Text('Reintentar')),
                  ],
                ),
              ),
            )
          : SelectionArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 1. Resumen general
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _statBox(
                        icon: Icons.access_time_filled,
                        color: brandSeed,
                        title: 'Tiempo total registrado',
                        value: _fmtMin(totalMin),
                        subtitle: '${doneTasks.length} completadas · ${pendingTasks.length} pendientes',
                        scheme: scheme,
                      ),
                      _statBox(
                        icon: Icons.track_changes,
                        color: const Color(0xFF00897B),
                        title: 'Precisión de estimaciones',
                        value: ratio == null ? 'Sin datos aún' : '${(ratio * 100).round()}% (${ratio}x)',
                        subtitle: ratio == null
                            ? 'Completa tareas con tiempo registrado'
                            : ratio > 1.1
                                ? 'Sueles tardar más de lo estimado'
                                : ratio < 0.9
                                    ? 'Terminas antes de lo estimado'
                                    : '¡Tus estimaciones son muy precisas!',
                        scheme: scheme,
                      ),
                      _statBox(
                        icon: overdue > 0 ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                        color: overdue > 0 ? Colors.redAccent : Colors.green.shade700,
                        title: 'Entregas vencidas',
                        value: '$overdue',
                        subtitle: overdue > 0 ? 'Requieren atención inmediata' : 'Ninguna tarea atrasada',
                        scheme: scheme,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text('Distribución de tiempo por contexto', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  for (final entry in [
                    ('universidad', '🎓 Universidad', contextColor('universidad')),
                    ('trabajo', '💼 Trabajo', contextColor('trabajo')),
                    ('personal', '🏠 Personal', contextColor('personal')),
                  ])
                    Builder(builder: (c) {
                      final m = ctxMap[entry.$1] ?? 0;
                      final pct = totalMin > 0 ? (m / totalMin).clamp(0.0, 1.0) : 0.0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(entry.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text('${_fmtMin(m)} (${(pct * 100).round()}%)',
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: LinearProgressIndicator(
                                value: pct,
                                minHeight: 10,
                                backgroundColor: entry.$3.withOpacity(0.14),
                                color: entry.$3,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  if (doneTasks.isNotEmpty) ...[
                    const Divider(height: 28),
                    Text('Comparativa Real vs. Estimado (Tareas completadas)',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final t in doneTasks.take(10))
                      Builder(builder: (c) {
                        final est = (t['estimate_min'] as num?)?.toInt() ?? 60;
                        final real = (t['logged_min'] as num?)?.toInt() ?? 0;
                        final diff = real - est;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.check_circle, color: Colors.green, size: 20),
                          title: Text(t['title'].toString(), style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('Estimado: ${_fmtMin(est)} · Real: ${_fmtMin(real)}'),
                          trailing: Text(
                            diff == 0
                                ? 'Exacto'
                                : diff > 0
                                    ? '+${_fmtMin(diff)}'
                                    : '-${_fmtMin(diff.abs())}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: diff > 15 ? Colors.orange.shade800 : Colors.green.shade700,
                            ),
                          ),
                        );
                      }),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _statBox({
    required IconData icon,
    required Color color,
    required String title,
    required String value,
    required String subtitle,
    required ColorScheme scheme,
  }) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(subtitle, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
