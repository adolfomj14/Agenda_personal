import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../theme.dart';
import 'weekly_schedule_sheet.dart';

enum _Kind { event, block, deadline }

class _Item {
  _Item(
    this.kind,
    this.title,
    this.start,
    this.end,
    this.ctx, {
    this.sub = '',
    this.description = '',
    this.location = '',
    this.url = '',
    this.done = false,
  });
  final _Kind kind;
  final String title;
  final DateTime start;
  final DateTime end;
  final String ctx;
  final String sub;
  final String description;
  final String location;
  final String url;
  final bool done;
}

class _Placed {
  _Placed(this.item, this.col);
  final _Item item;
  final int col;
  int cols = 1;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.api});
  final Api api;
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _byDay = <DateTime, List<_Item>>{};
  List<dynamic> _conflicts = [];
  int _atRisk = 0;
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  DateTime _focused = DateTime.now();
  DateTime _selected = _day(DateTime.now());
  CalendarFormat _format = CalendarFormat.month;

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
    _reload(silent: !_loading);
  }

  void _applyBundle(Map<String, dynamic> bundle) {
    _byDay.clear();
    void add(DateTime d, _Item i) => _byDay.putIfAbsent(_day(d), () => []).add(i);

    final events = (bundle['events'] as List?) ?? const [];
    final plan = (bundle['plan'] as Map?) ?? const {};
    final tasks = (bundle['tasks'] as List?) ?? const [];

    for (final e in events) {
      final s = DateTime.parse(e['start'].toString()).toLocal();
      final en = DateTime.parse(e['end'].toString()).toLocal();
      final ctx = (e['context'] ?? 'personal').toString();
      final title = e['title'].toString();
      final cal = e['calendar'].toString();
      final desc = (e['description'] ?? '').toString();
      final loc = (e['location'] ?? '').toString();
      final url = (e['url'] ?? '').toString();
      final allDay = e['all_day'] == true;
      if (allDay) {
        var d = _day(s);
        final last = _day(en.subtract(const Duration(seconds: 1)));
        do {
          add(d, _Item(_Kind.deadline, title, d, d, ctx, sub: cal, description: desc, location: loc, url: url));
          d = d.add(const Duration(days: 1));
        } while (!d.isAfter(last));
      } else if (!en.isAfter(s)) {
        add(s, _Item(_Kind.deadline, title, s, s, ctx, sub: cal, description: desc, location: loc, url: url));
      } else {
        add(s, _Item(_Kind.event, title, s, en, ctx, sub: cal, description: desc, location: loc, url: url));
      }
    }
    for (final b in (plan['blocks'] as List?) ?? const []) {
      final s = DateTime.parse(b['start'].toString()).toLocal();
      add(
        s,
        _Item(
          _Kind.block,
          b['title'].toString(),
          s,
          DateTime.parse(b['end'].toString()).toLocal(),
          'plan',
          sub: 'Bloque sugerido por el planificador',
          description: 'Bloque de tiempo reservado automáticamente para avanzar en esta tarea.',
        ),
      );
    }
    for (final t in tasks) {
      final d = DateTime.parse(t['deadline'].toString()).toLocal();
      final isDone = t['done'] == true;
      add(
        d,
        _Item(
          _Kind.deadline,
          '${isDone ? '✅' : '📌'} ${t['title']}',
          d,
          d,
          (t['context'] ?? 'personal').toString(),
          sub: isDone ? 'Tarea completada' : 'Entrega de tarea (${t['logged_min'] ?? 0}/${t['estimate_min']} min)',
          description: (t['description'] ?? '').toString(),
          done: isDone,
        ),
      );
    }
    _conflicts = (bundle['conflicts'] as List?) ?? const [];
    _atRisk = ((plan['statuses'] as List?) ?? const [])
        .where((x) => x['status'] == 'late' || x['status'] == 'at_risk')
        .length;
  }

  Future<void> _reload({bool silent = false, bool forceIcs = false}) async {
    if (mounted) {
      setState(() {
        _syncing = true;
        if (!silent) {
          _loading = true;
          _error = null;
        }
      });
    }
    try {
      final bundle = await widget.api.getBundle(days: 120, back: 45, refresh: forceIcs);
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _loading = false;
        _syncing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _syncing = false;
        if (_byDay.isEmpty) _error = '$e';
      });
    }
  }

  List<_Item> _itemsOf(DateTime d) => _byDay[_day(d)] ?? const [];

  // ---------- Ventana de detalles con texto seleccionable y copiado ----------
  Future<void> _showItemDetails(_Item item) async {
    final dateFmt = DateFormat("EEEE d 'de' MMMM yyyy", 'es');
    final hmFmt = DateFormat.Hm();
    final isTimed = item.kind != _Kind.deadline;
    final durMin = isTimed ? item.end.difference(item.start).inMinutes : 0;
    final timeStr = isTimed
        ? '${hmFmt.format(item.start)} – ${hmFmt.format(item.end)} ($durMin min)'
        : (item.start.hour == 0 && item.start.minute == 0
            ? 'Todo el día'
            : 'Hora límite: ${hmFmt.format(item.start)}');
    final isBusy = {'busy', 'ocupado', 'no disponible', 'unavailable'}
        .contains(item.title.trim().toLowerCase());

    final fullSummary = [
      item.title,
      'Fecha: ${dateFmt.format(item.start)}',
      'Horario: $timeStr',
      if (item.sub.isNotEmpty) 'Origen: ${item.sub}',
      'Contexto: ${item.ctx}',
      if (item.location.isNotEmpty) 'Ubicación: ${item.location}',
      if (item.description.isNotEmpty) '\nDescripción:\n${item.description}',
      if (item.url.isNotEmpty) '\nEnlace: ${item.url}',
    ].join('\n');

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: SelectionArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                item.kind == _Kind.block
                    ? Icons.timer_outlined
                    : item.kind == _Kind.deadline
                        ? Icons.flag_outlined
                        : Icons.event_outlined,
                color: item.kind == _Kind.block ? brandMint : contextColor(item.ctx),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectionArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow(Icons.calendar_today_outlined, 'Fecha', dateFmt.format(item.start)),
                  _detailRow(Icons.access_time, 'Horario', timeStr),
                  if (item.sub.isNotEmpty) _detailRow(Icons.source_outlined, 'Calendario / Origen', item.sub),
                  _detailRow(Icons.category_outlined, 'Contexto', item.ctx.toUpperCase()),
                  if (item.location.isNotEmpty) _detailRow(Icons.place_outlined, 'Ubicación', item.location),
                  if (item.description.isNotEmpty) ...[
                    const Divider(height: 20),
                    Text('Información / Descripción (seleccionable):',
                        style: Theme.of(c).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(c).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        item.description,
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
                      ),
                    ),
                  ],
                  if (item.url.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: () async {
                        final u = Uri.tryParse(item.url);
                        if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
                      },
                      child: Text(
                        item.url,
                        style: const TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                  if (isBusy) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.shade700.withOpacity(0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '¿Por qué aparece solo como "Busy / Ocupado"?',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Google Workspace en cuentas corporativas oculta los títulos en el enlace público iCal. '
                            'Puedes usar la "Dirección secreta en formato iCal" de Google Calendar o configurar tu Horario Semanal de Trabajo aquí mismo.',
                            style: TextStyle(fontSize: 12.5),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              Navigator.pop(c);
                              final changed = await showWeeklyScheduleModal(context, widget.api);
                              if (changed == true) _reload();
                            },
                            icon: const Icon(Icons.work_history_outlined, size: 18),
                            label: const Text('Configurar mi horario de trabajo'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: fullSummary));
              if (c.mounted) {
                ScaffoldMessenger.of(c).showSnackBar(
                  const SnackBar(content: Text('Información copiada al portapapeles'), duration: Duration(seconds: 2)),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copiar info'),
          ),
          if (item.kind != _Kind.block)
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(c);
                await widget.api.post('/tasks', {
                  'title': item.title.replaceFirst(RegExp(r'^[📌✅]\s*'), ''),
                  'context': item.ctx == 'plan' ? 'personal' : item.ctx,
                  'estimate_min': durMin > 0 ? durMin : 60,
                  'priority': 2,
                  'deadline': item.start.toIso8601String(),
                  'description': item.description,
                });
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Tarea creada a partir del evento')),
                  );
                }
                _reload(silent: true);
              },
              icon: const Icon(Icons.add_task, size: 18),
              label: const Text('Crear tarea'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            child: Text('$label:', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Row(children: [AppLogo(size: 30), SizedBox(width: 10), Text('Calendario')]),
        actions: [
          TextButton.icon(
            onPressed: () async {
              final changed = await showWeeklyScheduleModal(context, widget.api);
              if (changed == true) _reload();
            },
            icon: const Icon(Icons.work_history_outlined, size: 20),
            label: const Text('Mi horario'),
          ),
          IconButton(
            tooltip: 'Ir a hoy',
            icon: const Icon(Icons.today),
            onPressed: () => setState(() {
              _focused = DateTime.now();
              _selected = _day(DateTime.now());
            }),
          ),
          IconButton(
            tooltip: 'Actualizar calendarios',
            icon: const Icon(Icons.refresh),
            onPressed: () => _reload(forceIcs: true),
          ),
        ],
        bottom: _syncing && _byDay.isNotEmpty
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _loading && _byDay.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _byDay.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('$_error\n\nVersión: ${Api.appVersion}', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _reload, child: const Text('Reintentar')),
                    ]),
                  ),
                )
              : LayoutBuilder(builder: (c, box) {
                  final wide = box.maxWidth >= 900;
                  final cal = _calendar(context);
                  final day = _dayPanel(context);
                  if (wide) {
                    return Row(children: [
                      SizedBox(
                        width: 440,
                        child: SingleChildScrollView(child: Column(children: [cal, _banners()])),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: day),
                    ]);
                  }
                  return Column(children: [cal, _banners(), Expanded(child: day)]);
                }),
    );
  }

  Widget _banners() {
    final chips = <Widget>[];
    if (_atRisk > 0) {
      chips.add(_chip(Icons.warning_amber, '$_atRisk tarea(s) en riesgo', Colors.red));
    }
    if (_conflicts.isNotEmpty) {
      chips.add(_chip(Icons.event_busy, '${_conflicts.length} conflicto(s) de horario', Colors.orange));
    }
    if (chips.isEmpty) return const SizedBox(height: 4);
    return Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 4), child: Wrap(spacing: 8, children: chips));
  }

  Widget _chip(IconData i, String t, Color c) => Chip(
        avatar: Icon(i, size: 18, color: c),
        label: Text(t),
        backgroundColor: c.withOpacity(0.12),
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      );

  Widget _calendar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      color: scheme.surfaceContainerLow,
      child: TableCalendar<_Item>(
        locale: 'es',
        firstDay: DateTime.utc(2020),
        lastDay: DateTime.utc(2035),
        focusedDay: _focused,
        startingDayOfWeek: StartingDayOfWeek.monday,
        calendarFormat: _format,
        availableCalendarFormats: const {
          CalendarFormat.month: 'Mes',
          CalendarFormat.twoWeeks: '2 sem.',
          CalendarFormat.week: 'Semana',
        },
        selectedDayPredicate: (d) => isSameDay(d, _selected),
        eventLoader: _itemsOf,
        onDaySelected: (sel, foc) => setState(() {
          _selected = _day(sel);
          _focused = foc;
        }),
        onFormatChanged: (f) => setState(() => _format = f),
        onPageChanged: (f) => _focused = f,
        headerStyle: const HeaderStyle(titleCentered: true, formatButtonShowsNext: false),
        calendarStyle: CalendarStyle(
          todayDecoration: BoxDecoration(color: scheme.primary.withOpacity(0.25), shape: BoxShape.circle),
          todayTextStyle: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.bold),
          selectedDecoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          markersMaxCount: 4,
        ),
        calendarBuilders: CalendarBuilders<_Item>(
          markerBuilder: (c, day, items) {
            if (items.isEmpty) return const SizedBox();
            final ctxs = items.map((i) => i.kind == _Kind.block ? brandMint : contextColor(i.ctx)).toSet().take(4);
            return Positioned(
              bottom: 4,
              child: Row(children: [
                for (final col in ctxs)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1.2),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: col, shape: BoxShape.circle),
                  ),
              ]),
            );
          },
        ),
      ),
    );
  }

  // ---------- panel del día ----------
  Widget _dayPanel(BuildContext context) {
    final items = _itemsOf(_selected);
    final deadlines = items.where((i) => i.kind == _Kind.deadline).toList();
    final timed = items.where((i) => i.kind != _Kind.deadline).toList();
    final title = toBeginningOfSentenceCase(DateFormat("EEEE d 'de' MMMM", 'es').format(_selected));

    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
            _legend('Universidad', contextColor('universidad')),
            _legend('Trabajo', contextColor('trabajo')),
            _legend('Plan', brandMint),
          ]),
        ),
        if (deadlines.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final d in deadlines)
                ActionChip(
                  avatar: Icon(
                    d.done ? Icons.check_circle : Icons.flag,
                    size: 16,
                    color: d.done ? Colors.green : contextColor(d.ctx),
                  ),
                  label: Text(
                    d.start.hour == 0 && d.start.minute == 0
                        ? d.title
                        : '${DateFormat.Hm().format(d.start)}  ${d.title}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      decoration: d.done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  backgroundColor: contextColor(d.ctx).withOpacity(0.10),
                  side: BorderSide(color: contextColor(d.ctx).withOpacity(0.4)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showItemDetails(d),
                ),
            ]),
          ),
        Expanded(child: _timeline(timed)),
      ]),
    );
  }

  Widget _legend(String t, Color c) => Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11)),
        ]),
      );

  static const _hourH = 58.0;

  Widget _timeline(List<_Item> timed) {
    final dayStart = _selected;
    final dayEnd = _selected.add(const Duration(days: 1));
    var firstHour = 7, lastHour = 22;
    for (final i in timed) {
      firstHour = math.min(firstHour, i.start.hour);
      final e = i.end.isAfter(dayEnd) ? dayEnd : i.end;
      lastHour = math.max(lastHour, e.hour + (e.minute > 0 ? 1 : 0));
    }
    lastHour = math.min(lastHour, 24);
    final total = (lastHour - firstHour) * _hourH;

    final placed = _layout(timed);
    final isToday = isSameDay(_selected, DateTime.now());
    final now = DateTime.now();

    return LayoutBuilder(builder: (c, box) {
      const left = 52.0;
      final width = box.maxWidth - left - 12;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 24),
        child: SizedBox(
          height: total + 8,
          child: Stack(children: [
            for (var h = firstHour; h <= lastHour; h++)
              Positioned(
                top: (h - firstHour) * _hourH,
                left: 0,
                right: 0,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: left - 6,
                    child: Transform.translate(
                      offset: const Offset(0, -7),
                      child: Text(
                        '${h.toString().padLeft(2, '0')}:00',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(child: Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant)),
                ]),
              ),
            for (final p in placed) _block(p, firstHour, left, width, dayStart, dayEnd),
            if (isToday && now.hour >= firstHour && now.hour < lastHour)
              Positioned(
                top: ((now.hour - firstHour) * 60 + now.minute) / 60 * _hourH,
                left: left - 8,
                right: 0,
                child: Row(children: [
                  Container(width: 9, height: 9, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                  Expanded(child: Container(height: 1.5, color: Colors.red)),
                ]),
              ),
            if (timed.isEmpty)
              Positioned(
                top: 40,
                left: left,
                right: 0,
                child: Center(
                  child: Text(
                    'Sin eventos ni bloques este día.\nPulsa "Mi horario" arriba si quieres añadir tu jornada laboral o clases fijas.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ),
          ]),
        ),
      );
    });
  }

  Widget _block(_Placed p, int firstHour, double left, double width, DateTime dayStart, DateTime dayEnd) {
    final i = p.item;
    final s = i.start.isBefore(dayStart) ? dayStart : i.start;
    final e = i.end.isAfter(dayEnd) ? dayEnd : i.end;
    final minutes = math.max(30, e.difference(s).inMinutes);
    final top = ((s.hour - firstHour) * 60 + s.minute) / 60 * _hourH;
    final height = minutes / 60 * _hourH - 2;
    final colW = width / p.cols;
    final isBlock = i.kind == _Kind.block;
    final color = isBlock ? brandMint : contextColor(i.ctx);
    return Positioned(
      top: top + 1,
      left: left + colW * p.col,
      width: colW - 3,
      height: height,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showItemDetails(i),
          child: Tooltip(
            message: 'Pulsa para ver y copiar información completa',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withOpacity(isBlock ? 0.18 : 0.88),
                borderRadius: BorderRadius.circular(8),
                border: Border(left: BorderSide(color: color, width: 4)),
              ),
              clipBehavior: Clip.hardEdge,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '${isBlock ? '⏱ ' : ''}${i.title}',
                  maxLines: height > 48 ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                    color: isBlock ? Theme.of(context).colorScheme.onSurface : Colors.white,
                  ),
                ),
                if (height > 40)
                  Text(
                    '${DateFormat.Hm().format(i.start)} – ${DateFormat.Hm().format(i.end)}${i.sub.isEmpty ? '' : ' · ${i.sub}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: isBlock ? Theme.of(context).colorScheme.onSurfaceVariant : Colors.white70,
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  List<_Placed> _layout(List<_Item> items) {
    final sorted = [...items]..sort((a, b) => a.start.compareTo(b.start));
    final out = <_Placed>[];
    var cluster = <_Placed>[];
    final colEnds = <DateTime>[];
    DateTime? clusterEnd;

    DateTime endOf(_Item i) {
      final min = i.start.add(const Duration(minutes: 30));
      return i.end.isAfter(min) ? i.end : min;
    }

    void flush() {
      final n = cluster.fold<int>(1, (m, p) => math.max(m, p.col + 1));
      for (final p in cluster) {
        p.cols = n;
      }
      out.addAll(cluster);
      cluster = [];
      colEnds.clear();
      clusterEnd = null;
    }

    for (final it in sorted) {
      if (clusterEnd != null && !it.start.isBefore(clusterEnd!)) flush();
      var col = colEnds.indexWhere((e) => !e.isAfter(it.start));
      if (col == -1) {
        col = colEnds.length;
        colEnds.add(endOf(it));
      } else {
        colEnds[col] = endOf(it);
      }
      cluster.add(_Placed(it, col));
      final e = endOf(it);
      if (clusterEnd == null || e.isAfter(clusterEnd!)) clusterEnd = e;
    }
    flush();
    return out;
  }
}
