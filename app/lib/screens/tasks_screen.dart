import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api.dart';
import '../theme.dart';

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.api});
  final Api api;
  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<Map<String, dynamic>> _tasks = [];
  Map<int, Map<String, dynamic>> _statuses = {};
  bool _loading = true;
  String? _error;

  // Filtros: 'all' | 'pending' | 'done'
  String _statusFilter = 'all';
  // Contexto: 'all' | 'universidad' | 'trabajo' | 'personal'
  String _ctxFilter = 'all';

  // Cronómetro en vivo (actualización por segundo)
  int? _timerTaskId;
  DateTime? _timerStart;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  void _initLoad() {
    final cached = widget.api.peekCache('bundle');
    if (cached is Map) {
      _applyBundle(Map<String, dynamic>.from(cached));
      _loading = false;
    }
    _refresh(silent: !_loading);
  }

  void _applyBundle(Map<String, dynamic> bundle) {
    final rawTasks = (bundle['tasks'] as List?) ?? const [];
    _tasks = [for (final t in rawTasks) Map<String, dynamic>.from(t as Map)];
    final plan = (bundle['plan'] as Map?) ?? const {};
    final rawStatuses = (plan['statuses'] as List?) ?? const [];
    _statuses = {
      for (final s in rawStatuses)
        ((s as Map)['task_id'] as num).toInt(): Map<String, dynamic>.from(s),
    };
  }

  Future<void> _refresh({bool silent = false, bool forceIcs = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final bundle = await widget.api.getBundle(refresh: forceIcs);
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_tasks.isEmpty) _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  // ---------- Cronómetro y registro de tiempo ----------
  int get _elapsedSeconds =>
      _timerStart == null ? 0 : DateTime.now().difference(_timerStart!).inSeconds;

  String _formatClock(int totalSec) {
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatMin(int mins) {
    if (mins <= 0) return '0 min';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  Future<void> _toggleTimer(int id) async {
    if (_timerTaskId == id) {
      final mins = (_elapsedSeconds / 60).ceil().clamp(1, 1440);
      _tick?.cancel();
      setState(() {
        _timerTaskId = null;
        _timerStart = null;
      });
      await _logMinutes(id, mins);
    } else {
      _tick?.cancel();
      setState(() {
        _timerTaskId = id;
        _timerStart = DateTime.now();
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _cancelTimer() {
    _tick?.cancel();
    setState(() {
      _timerTaskId = null;
      _timerStart = null;
    });
  }

  Future<void> _logMinutes(int id, int mins) async {
    // Actualización optimista inmediata
    final idx = _tasks.indexWhere((t) => (t['id'] as num).toInt() == id);
    if (idx != -1) {
      setState(() {
        _tasks[idx]['logged_min'] = ((_tasks[idx]['logged_min'] as num?)?.toInt() ?? 0) + mins;
      });
    }
    try {
      await widget.api.post('/tasks/$id/log', {'minutes': mins});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('+$mins min registrados'), duration: const Duration(seconds: 2)),
        );
      }
      await _refresh(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al registrar tiempo: $e')));
      }
      await _refresh(silent: true);
    }
  }

  Future<void> _toggleDone(Map<String, dynamic> task, bool newDone) async {
    final id = (task['id'] as num).toInt();
    // Actualización optimista inmediata: la tarea NO desaparece, se marca visualmente
    setState(() {
      task['done'] = newDone;
      if (newDone) {
        _statuses[id] = {'task_id': id, 'status': 'done', 'remaining_min': 0, 'unscheduled_min': 0};
      }
    });
    try {
      await widget.api.patch('/tasks/$id', {'done': newDone});
      await _refresh(silent: true);
    } catch (e) {
      setState(() => task['done'] = !newDone);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo actualizar: $e')));
      }
    }
  }

  // ---------- Crear / Editar tarea ----------
  Future<void> _openTaskEditor([Map<String, dynamic>? existing]) async {
    final title = TextEditingController(text: existing?['title']?.toString() ?? '');
    final desc = TextEditingController(text: existing?['description']?.toString() ?? '');
    final est = TextEditingController(text: (existing?['estimate_min'] ?? 60).toString());
    final logged = TextEditingController(text: (existing?['logged_min'] ?? 0).toString());
    var ctx = existing?['context']?.toString() ?? 'universidad';
    var prio = (existing?['priority'] as num?)?.toInt() ?? 2;
    var deadline = existing != null
        ? DateTime.parse(existing['deadline'].toString()).toLocal()
        : DateTime.now().add(const Duration(days: 2));
    final isCanvas = (existing?['source_uid'] ?? '').toString().isNotEmpty;

    final result = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Row(
            children: [
              Expanded(child: Text(existing == null ? 'Nueva tarea' : 'Detalles y edición')),
              if (existing != null)
                IconButton(
                  tooltip: 'Eliminar tarea',
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () => Navigator.pop(c, 'delete'),
                ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: SelectionArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isCanvas)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: contextColor('universidad').withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.school, size: 16),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Importada automáticamente desde el calendario de Canvas (Universidad)',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                    TextField(
                      controller: title,
                      decoration: const InputDecoration(labelText: 'Título de la tarea'),
                      autofocus: existing == null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: ctx,
                            decoration: const InputDecoration(labelText: 'Contexto'),
                            items: const [
                              DropdownMenuItem(value: 'universidad', child: Text('🎓 Universidad')),
                              DropdownMenuItem(value: 'trabajo', child: Text('💼 Trabajo')),
                              DropdownMenuItem(value: 'personal', child: Text('🏠 Personal')),
                            ],
                            onChanged: (v) => set(() => ctx = v!),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: prio,
                            decoration: const InputDecoration(labelText: 'Prioridad'),
                            items: const [
                              DropdownMenuItem(value: 1, child: Text('Baja')),
                              DropdownMenuItem(value: 2, child: Text('Media')),
                              DropdownMenuItem(value: 3, child: Text('🔥 Alta')),
                            ],
                            onChanged: (v) => set(() => prio = v!),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: est,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Tiempo estimado (min)',
                              prefixIcon: Icon(Icons.flag_outlined),
                            ),
                          ),
                        ),
                        if (existing != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: logged,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Tiempo dedicado (min)',
                                prefixIcon: Icon(Icons.timer_outlined),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final m in [30, 60, 90, 120, 180])
                          ActionChip(
                            label: Text('Est: ${_formatMin(m)}'),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => set(() => est.text = '$m'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('Fecha límite de entrega'),
                      subtitle: Text(DateFormat("EEEE d 'de' MMM, HH:mm", 'es').format(deadline)),
                      trailing: OutlinedButton(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: c,
                            initialDate: deadline,
                            firstDate: DateTime.now().subtract(const Duration(days: 365)),
                            lastDate: DateTime.now().add(const Duration(days: 730)),
                          );
                          if (d == null || !c.mounted) return;
                          final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(deadline));
                          set(() => deadline = DateTime(d.year, d.month, d.day, t?.hour ?? 23, t?.minute ?? 59));
                        },
                        child: const Text('Cambiar'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: desc,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Descripción / instrucciones / enlaces',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Guardar')),
          ],
        ),
      ),
    );

    if (result == 'delete' && existing != null) {
      await widget.api.delete('/tasks/${existing['id']}');
      await _refresh(silent: true);
      return;
    }
    if (result != 'save' || title.text.trim().isEmpty) return;

    final estMin = (int.tryParse(est.text.trim()) ?? 60).clamp(5, 10000);
    if (existing == null) {
      await widget.api.post('/tasks', {
        'title': title.text.trim(),
        'context': ctx,
        'estimate_min': estMin,
        'priority': prio,
        'deadline': deadline.toIso8601String(),
        'description': desc.text.trim(),
      });
    } else {
      final loggedMin = (int.tryParse(logged.text.trim()) ?? 0).clamp(0, 100000);
      await widget.api.patch('/tasks/${existing['id']}', {
        'title': title.text.trim(),
        'context': ctx,
        'estimate_min': estMin,
        'priority': prio,
        'deadline': deadline.toIso8601String(),
        'description': desc.text.trim(),
        'logged_min': loggedMin,
      });
    }
    await _refresh(silent: true);
  }

  String _relativeDeadline(DateTime dl, bool isDone) {
    if (isDone) return 'Completada';
    final diff = dl.difference(DateTime.now());
    if (diff.isNegative) {
      final mins = diff.inMinutes.abs();
      if (mins < 60) return 'Vencida hace $mins min';
      if (mins < 1440) return 'Vencida hace ${diff.inHours.abs()} h';
      return 'Vencida hace ${diff.inDays.abs()} d';
    }
    if (diff.inMinutes < 60) return 'En ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'En ${diff.inHours} h';
    return 'En ${diff.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _tasks.where((t) => t['done'] != true).length;
    final doneCount = _tasks.where((t) => t['done'] == true).length;

    final filtered = _tasks.where((t) {
      final isDone = t['done'] == true;
      if (_statusFilter == 'pending' && isDone) return false;
      if (_statusFilter == 'done' && !isDone) return false;
      if (_ctxFilter != 'all' && t['context'] != _ctxFilter) return false;
      return true;
    }).toList();

    // Métricas de tiempo
    var remainingMin = 0;
    var totalLoggedMin = 0;
    var atRiskCount = 0;
    for (final t in _tasks) {
      final est = (t['estimate_min'] as num?)?.toInt() ?? 60;
      final log = (t['logged_min'] as num?)?.toInt() ?? 0;
      totalLoggedMin += log;
      if (t['done'] != true) {
        remainingMin += (est - log).clamp(0, 100000);
        final st = _statuses[(t['id'] as num).toInt()]?['status'];
        if (st == 'late' || st == 'at_risk') atRiskCount++;
      }
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Row(
          children: [
            AppLogo(size: 30),
            SizedBox(width: 10),
            Text('Tareas y Tiempos'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Importar entregas de Canvas (Universidad)',
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: () async {
              final cals = await widget.api.get('/calendars') as List;
              final uniCals = cals.where((c) => c['context'] == 'universidad').toList();
              if (uniCals.isEmpty) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Añade primero tu calendario .ics de Canvas en Ajustes')),
                  );
                }
                return;
              }
              var n = 0;
              for (final c in uniCals) {
                final res = await widget.api.post('/calendars/${c['id']}/import-tasks') as Map;
                n += (res['imported'] as num?)?.toInt() ?? 0;
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$n entregas nuevas importadas desde Canvas')),
                );
              }
              await _refresh(forceIcs: true);
            },
          ),
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(forceIcs: true),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTaskEditor(),
        icon: const Icon(Icons.add_task),
        label: const Text('Nueva tarea'),
      ),
      body: _loading && _tasks.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _tasks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$_error', textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _refresh, child: const Text('Reintentar')),
                      ],
                    ),
                  ),
                )
              : SelectionArea(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 92),
                    children: [
                      // 1. Panel de resumen de tiempos
                      _buildSummaryBanner(remainingMin, totalLoggedMin, pendingCount, doneCount, atRiskCount),
                      const SizedBox(height: 10),
                      // 2. Cronómetro activo en vivo (si está corriendo)
                      if (_timerTaskId != null) _buildLiveTimerCard(),
                      // 3. Filtros por estado (Todas / Pendientes / Completadas) y por contexto
                      _buildFilters(pendingCount, doneCount),
                      const SizedBox(height: 8),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Center(
                            child: Text(
                              _tasks.isEmpty
                                  ? 'No hay tareas aún.\nCrea una con el botón "Nueva tarea" o importa tus entregas de Canvas arriba.'
                                  : 'No hay tareas en este filtro.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      for (final t in filtered) _buildTaskCard(t),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSummaryBanner(int remainingMin, int totalLoggedMin, int pending, int done, int atRisk) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _kpiCard(
          icon: Icons.hourglass_bottom,
          color: brandSeed,
          label: 'Tiempo pendiente',
          value: _formatMin(remainingMin),
          sub: '$pending por hacer',
          scheme: scheme,
        ),
        _kpiCard(
          icon: Icons.timer_outlined,
          color: const Color(0xFF00897B),
          label: 'Tiempo dedicado',
          value: _formatMin(totalLoggedMin),
          sub: '$done completadas',
          scheme: scheme,
        ),
        _kpiCard(
          icon: atRisk > 0 ? Icons.warning_amber_rounded : Icons.verified_outlined,
          color: atRisk > 0 ? Colors.orange.shade800 : Colors.green.shade700,
          label: 'Estado del plan',
          value: atRisk > 0 ? '$atRisk en riesgo' : 'Al día',
          sub: atRisk > 0 ? 'Revisa prioridades' : 'Todo entra en horario',
          scheme: scheme,
        ),
      ],
    );
  }

  Widget _kpiCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    required String sub,
    required ColorScheme scheme,
  }) {
    return Container(
      width: 210,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: color.withOpacity(0.14),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                Text(sub, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTimerCard() {
    final activeTask = _tasks.cast<Map<String, dynamic>?>().firstWhere(
          (t) => (t?['id'] as num?)?.toInt() == _timerTaskId,
          orElse: () => null,
        );
    final title = activeTask?['title']?.toString() ?? 'Tarea';
    final minsToSave = (_elapsedSeconds / 60).ceil().clamp(1, 1440);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF3F3FBF), Color(0xFF7C6CF0)]),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.timelapse, color: Colors.white, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'En curso: $title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                Text(
                  _formatClock(_elapsedSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _cancelTimer,
            child: const Text('Descartar', style: TextStyle(color: Colors.white70)),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: brandMint, foregroundColor: Colors.black87),
            onPressed: () => _toggleTimer(_timerTaskId!),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text('Guardar +$minsToSave m'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(int pendingCount, int doneCount) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                label: Text('Todas (${_tasks.length})'),
                selected: _statusFilter == 'all',
                onSelected: (_) => setState(() => _statusFilter = 'all'),
              ),
              const SizedBox(width: 6),
              ChoiceChip(
                label: Text('Pendientes ($pendingCount)'),
                selected: _statusFilter == 'pending',
                onSelected: (_) => setState(() => _statusFilter = 'pending'),
              ),
              const SizedBox(width: 6),
              ChoiceChip(
                label: Text('Completadas ($doneCount)'),
                selected: _statusFilter == 'done',
                onSelected: (_) => setState(() => _statusFilter = 'done'),
              ),
              const SizedBox(width: 14),
              FilterChip(
                label: const Text('🎓 Universidad'),
                selected: _ctxFilter == 'universidad',
                onSelected: (v) => setState(() => _ctxFilter = v ? 'universidad' : 'all'),
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('💼 Trabajo'),
                selected: _ctxFilter == 'trabajo',
                onSelected: (v) => setState(() => _ctxFilter = v ? 'trabajo' : 'all'),
              ),
              const SizedBox(width: 6),
              FilterChip(
                label: const Text('🏠 Personal'),
                selected: _ctxFilter == 'personal',
                onSelected: (v) => setState(() => _ctxFilter = v ? 'personal' : 'all'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTaskCard(Map<String, dynamic> t) {
    final id = (t['id'] as num).toInt();
    final isDone = t['done'] == true;
    final ctx = (t['context'] ?? 'personal').toString();
    final cColor = contextColor(ctx);
    final prio = (t['priority'] as num?)?.toInt() ?? 2;
    final est = ((t['estimate_min'] as num?)?.toInt() ?? 60).clamp(1, 100000);
    final logged = (t['logged_min'] as num?)?.toInt() ?? 0;
    final running = _timerTaskId == id;
    final liveAddMin = running ? (_elapsedSeconds ~/ 60) : 0;
    final shownLogged = logged + liveAddMin;
    final progress = (shownLogged / est).clamp(0.0, 1.0);
    final restMin = (est - shownLogged).clamp(0, 100000);

    final deadline = DateTime.parse(t['deadline'].toString()).toLocal();
    final stInfo = _statuses[id];
    final status = isDone ? 'done' : (stInfo?['status']?.toString() ?? 'ok');
    final stColor = statusColors[status] ?? Colors.grey;
    final stLabel = isDone ? 'Completada' : (statusLabels[status] ?? status);
    final desc = (t['description'] ?? '').toString().trim();
    final isCanvas = (t['source_uid'] ?? '').toString().isNotEmpty;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDone
          ? scheme.surfaceContainerHighest.withOpacity(0.45)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: running
              ? brandSeed
              : isDone
                  ? Colors.green.withOpacity(0.35)
                  : cColor.withOpacity(0.35),
          width: running ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openTaskEditor(t),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: isDone,
                    activeColor: Colors.green.shade700,
                    onChanged: (v) => _toggleDone(t, v ?? !isDone),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  t['title'].toString(),
                                  style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700,
                                    decoration: isDone ? TextDecoration.lineThrough : null,
                                    color: isDone ? scheme.onSurfaceVariant : scheme.onSurface,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: stColor.withOpacity(0.16),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  stLabel,
                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: stColor),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              _pill(
                                ctx == 'universidad'
                                    ? '🎓 Universidad'
                                    : ctx == 'trabajo'
                                        ? '💼 Trabajo'
                                        : '🏠 Personal',
                                cColor,
                              ),
                              if (isCanvas) _pill('Canvas', Colors.deepPurple),
                              if (prio == 3)
                                _pill('🔥 Prioridad alta', Colors.redAccent)
                              else if (prio == 1)
                                _pill('Prioridad baja', Colors.blueGrey),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.event, size: 14, color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${DateFormat('EEE d MMM HH:mm', 'es').format(deadline)} (${_relativeDeadline(deadline, isDone)})',
                                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          if (desc.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              desc,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                            ),
                          ],
                          const SizedBox(height: 10),
                          // Barra visual de tiempo (dedicado vs estimado)
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Tiempo: ${_formatMin(shownLogged)} / ${_formatMin(est)} (${(progress * 100).round()}%)',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                        ),
                                        Text(
                                          isDone
                                              ? '¡Lista!'
                                              : restMin > 0
                                                  ? 'Faltan ${_formatMin(restMin)}'
                                                  : 'Tiempo estimado cubierto',
                                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: LinearProgressIndicator(
                                        value: isDone ? 1.0 : progress,
                                        minHeight: 7,
                                        backgroundColor: cColor.withOpacity(0.14),
                                        color: isDone
                                            ? Colors.green
                                            : shownLogged > est
                                                ? Colors.orange
                                                : cColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Botones rápidos de tiempo y edición
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: running ? Colors.red.withOpacity(0.18) : null,
                                ),
                                onPressed: () => _toggleTimer(id),
                                icon: Icon(
                                  running ? Icons.stop_circle : Icons.play_arrow_rounded,
                                  size: 18,
                                  color: running ? Colors.red : null,
                                ),
                                label: Text(running ? _formatClock(_elapsedSeconds) : 'Cronómetro'),
                              ),
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                                onPressed: () => _logMinutes(id, 15),
                                child: const Text('+15m', style: TextStyle(fontSize: 12)),
                              ),
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                                onPressed: () => _logMinutes(id, 30),
                                child: const Text('+30m', style: TextStyle(fontSize: 12)),
                              ),
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                ),
                                onPressed: () => _logMinutes(id, 60),
                                child: const Text('+1h', style: TextStyle(fontSize: 12)),
                              ),
                              TextButton.icon(
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                onPressed: () => _openTaskEditor(t),
                                icon: const Icon(Icons.edit_outlined, size: 16),
                                label: const Text('Editar', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
