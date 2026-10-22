import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../api.dart';
import '../theme.dart';

enum _Kind { event, block, deadline }

class _Item {
  _Item(this.kind, this.title, this.start, this.end, this.ctx, [this.sub = '']);
  final _Kind kind;
  final String title;
  final DateTime start;
  final DateTime end;
  final String ctx;
  final String sub;
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
  late Future<void> _f = _load();
  final _byDay = <DateTime, List<_Item>>{};
  List<dynamic> _conflicts = [];
  int _atRisk = 0;
  DateTime _focused = DateTime.now();
  DateTime _selected = _day(DateTime.now());
  CalendarFormat _format = CalendarFormat.month;

  Future<void> _load() async {
    final ev = await widget.api.get('/events?days=120&back=45') as Map;
    final plan = await widget.api.get('/plan?days=30') as Map;
    final tasks = await widget.api.get('/tasks') as List;
    _byDay.clear();
    void add(DateTime d, _Item i) => _byDay.putIfAbsent(_day(d), () => []).add(i);

    for (final e in ev['events'] as List) {
      final s = DateTime.parse(e['start']).toLocal();
      final en = DateTime.parse(e['end']).toLocal();
      final ctx = (e['context'] ?? 'personal').toString();
      final title = e['title'].toString();
      final cal = e['calendar'].toString();
      final allDay = e['all_day'] == true;
      if (allDay) {
        // Fin exclusivo: abarca cada día completo
        var d = _day(s);
        final last = _day(en.subtract(const Duration(seconds: 1)));
        do {
          add(d, _Item(_Kind.deadline, title, d, d, ctx, cal));
          d = d.add(const Duration(days: 1));
        } while (!d.isAfter(last));
      } else if (!en.isAfter(s)) {
        add(s, _Item(_Kind.deadline, title, s, s, ctx, cal)); // entrega puntual (Canvas)
      } else {
        add(s, _Item(_Kind.event, title, s, en, ctx, cal));
      }
    }
    for (final b in plan['blocks'] as List) {
      final s = DateTime.parse(b['start']).toLocal();
      add(s, _Item(_Kind.block, b['title'].toString(), s, DateTime.parse(b['end']).toLocal(), 'plan', 'Plan sugerido'));
    }
    for (final t in tasks) {
      final d = DateTime.parse(t['deadline']).toLocal();
      add(d, _Item(_Kind.deadline, '📌 ${t['title']}', d, d, (t['context'] ?? 'personal').toString(), 'Tarea'));
    }
    _conflicts = ev['conflicts'] as List;
    _atRisk = (plan['statuses'] as List).where((x) => x['status'] == 'late' || x['status'] == 'at_risk').length;
  }

  void _reload() => setState(() => _f = _load());

  List<_Item> _itemsOf(DateTime d) => _byDay[_day(d)] ?? const [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: const Row(children: [AppLogo(size: 30), SizedBox(width: 10), Text('Calendario')]),
        actions: [
          IconButton(
            tooltip: 'Ir a hoy',
            icon: const Icon(Icons.today),
            onPressed: () => setState(() {
              _focused = DateTime.now();
              _selected = _day(DateTime.now());
            }),
          ),
          IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<void>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (s.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${s.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('Reintentar')),
                ]),
              ),
            );
          }
          return LayoutBuilder(builder: (c, box) {
            final wide = box.maxWidth >= 900;
            final cal = _calendar(context);
            final day = _dayPanel(context);
            if (wide) {
              return Row(children: [
                SizedBox(width: 440, child: SingleChildScrollView(child: Column(children: [cal, _banners()]))),
                const VerticalDivider(width: 1),
                Expanded(child: day),
              ]);
            }
            return Column(children: [cal, _banners(), Expanded(child: day)]);
          });
        },
      ),
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
                  Container(margin: const EdgeInsets.symmetric(horizontal: 1.2), width: 6, height: 6, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
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
    final title = toBeginningOfSentenceCase(DateFormat("EEEE d 'de' MMMM", 'es').format(_selected))!;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          child: Wrap(spacing: 6, runSpacing: 2, children: [
            for (final d in deadlines)
              Chip(
                avatar: Icon(Icons.flag, size: 16, color: contextColor(d.ctx)),
                label: Text(
                  d.start.hour == 0 && d.start.minute == 0 ? d.title : '${DateFormat.Hm().format(d.start)}  ${d.title}',
                  overflow: TextOverflow.ellipsis,
                ),
                backgroundColor: contextColor(d.ctx).withOpacity(0.10),
                side: BorderSide(color: contextColor(d.ctx).withOpacity(0.4)),
                visualDensity: VisualDensity.compact,
              ),
          ]),
        ),
      Expanded(child: _timeline(timed)),
    ]);
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
                      child: Text('${h.toString().padLeft(2, '0')}:00',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
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
                  child: Text('Sin eventos ni bloques este día', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
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
    var e = i.end.isAfter(dayEnd) ? dayEnd : i.end;
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
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5, color: isBlock ? Theme.of(context).colorScheme.onSurface : Colors.white),
          ),
          if (height > 40)
            Text(
              '${DateFormat.Hm().format(i.start)} – ${DateFormat.Hm().format(i.end)}${i.sub.isEmpty ? '' : ' · ${i.sub}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: isBlock ? Theme.of(context).colorScheme.onSurfaceVariant : Colors.white70),
            ),
        ]),
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
