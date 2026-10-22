import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api, required this.onSaved});
  final Api api;
  final VoidCallback onSaved;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _url = TextEditingController(text: widget.api.baseUrl);
  late final _key = TextEditingController(text: widget.api.key);
  final _name = TextEditingController();
  final _ics = TextEditingController();
  String _ctx = 'universidad';
  late Future<dynamic> _cals = widget.api.get('/calendars');

  Future<void> _addCal() async {
    if (_name.text.isEmpty || _ics.text.isEmpty) return;
    await widget.api.post('/calendars', {'name': _name.text, 'context': _ctx, 'url': _ics.text.trim()});
    _name.clear();
    _ics.clear();
    setState(() => _cals = widget.api.get('/calendars'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ajustes')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Row(children: [
            AppLogo(size: 56),
            SizedBox(width: 14),
            Expanded(child: Text('Agenda personal\nUniversidad + Trabajo en un solo lugar', style: TextStyle(fontSize: 15))),
          ]),
          const SizedBox(height: 20),
          Text('Servidor', style: Theme.of(context).textTheme.titleMedium),
          TextField(controller: _url, decoration: const InputDecoration(labelText: 'URL del servidor')),
          TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              await Api.save(_url.text, _key.text);
              widget.onSaved();
            },
            child: const Text('Guardar'),
          ),
          const Divider(height: 32),
          Text('Calendarios (enlace ICS de Canvas / Google Calendar)', style: Theme.of(context).textTheme.titleMedium),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre (ej. Canvas)')),
          DropdownButtonFormField<String>(
            value: _ctx,
            items: const ['universidad', 'trabajo', 'personal'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) => setState(() => _ctx = v!),
          ),
          TextField(controller: _ics, decoration: const InputDecoration(labelText: 'Enlace .ics')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _addCal, child: const Text('Añadir calendario')),
          FutureBuilder<dynamic>(
            future: _cals,
            builder: (c, s) => Column(children: [
              for (final cal in (s.data as List? ?? []))
                ListTile(
                  title: Text(cal['name']),
                  subtitle: Text(cal['context']),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await widget.api.delete('/calendars/${cal['id']}');
                      setState(() => _cals = widget.api.get('/calendars'));
                    },
                  ),
                ),
            ]),
          ),
        ]),
      );
}
