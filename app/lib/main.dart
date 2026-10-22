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

  @override
  void initState() {
    super.initState();
    _loadApi();
  }

  Future<void> _loadApi() async {
    final a = await Api.load();
    setState(() {
      _api = a;
      _reload++;
    });
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
    return Scaffold(
      body: Row(children: [
        if (wide)
          NavigationRail(
            selectedIndex: _i,
            onDestinationSelected: (v) => setState(() => _i = v),
            labelType: NavigationRailLabelType.all,
            destinations: [for (final d in dests) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2))],
          ),
        Expanded(child: pages[_i]),
      ]),
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
