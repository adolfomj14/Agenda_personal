import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'api.dart';
import 'theme.dart';
import 'screens/calendar_screen.dart';
import 'screens/tasks_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  runApp(const AgendaApp());
}

class AgendaApp extends StatelessWidget {
  const AgendaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Agenda personal',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _i = 0;
  Api? _api;
  int _reload = 0; // cambia para forzar recarga de pantallas
  Timer? _globalTick;

  @override
  void initState() {
    super.initState();
    _loadApi();
    Api.activeTimer.addListener(_onTimerChanged);
  }

  @override
  void dispose() {
    Api.activeTimer.removeListener(_onTimerChanged);
    _globalTick?.cancel();
    super.dispose();
  }

  void _onTimerChanged() {
    _globalTick?.cancel();
    if (Api.activeTimer.value != null) {
      _globalTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _i != 1) setState(() {});
      });
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadApi() async {
    final a = await Api.load();
    _onTimerChanged();
    if (!mounted) return;
    setState(() {
      _api = a;
      _reload++;
    });
  }

  String _fmtClock(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    if (api == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final pages = [
      CalendarScreen(key: ValueKey('t$_reload'), api: api),
      TasksScreen(key: ValueKey('k$_reload'), api: api),
      NotesScreen(key: ValueKey('n$_reload'), api: api),
      SettingsScreen(api: api, onSaved: _loadApi),
    ];
    final wide = MediaQuery.of(context).size.width >= 700; // PC: barra lateral
    const dests = [
      (Icons.calendar_month, 'Calendario'),
      (Icons.checklist, 'Tareas'),
      (Icons.sticky_note_2_outlined, 'Notas'),
      (Icons.settings, 'Ajustes'),
    ];
    final timer = Api.activeTimer.value;

    return Scaffold(
      body: Column(
        children: [
          if (timer != null && _i != 1)
            Material(
              color: brandSeed,
              child: SafeArea(
                bottom: false,
                child: InkWell(
                  onTap: () => setState(() => _i = 1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.timelapse, color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Cronómetro activo: ${timer.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                        Text(
                          _fmtClock(timer.elapsedSeconds),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'monospace',
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, color: Colors.white70, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: Row(children: [
              if (wide)
                NavigationRail(
                  selectedIndex: _i,
                  onDestinationSelected: (v) => setState(() => _i = v),
                  labelType: NavigationRailLabelType.all,
                  destinations: [
                    for (final d in dests) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2))
                  ],
                ),
              Expanded(child: pages[_i]),
            ]),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _i,
              onDestinationSelected: (v) => setState(() => _i = v),
              destinations: [for (final d in dests) NavigationDestination(icon: Icon(d.$1), label: d.$2)],
            ),
    );
  }
}
