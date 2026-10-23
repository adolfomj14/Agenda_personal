import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'weekly_schedule_sheet.dart';

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
  late Future<dynamic> _wbs = widget.api.get('/weekly-blocks');

  Future<void> _addCal() async {
    if (_name.text.isEmpty || _ics.text.isEmpty) return;
    await widget.api.post('/calendars', {'name': _name.text.trim(), 'context': _ctx, 'url': _ics.text.trim()});
    _name.clear();
    _ics.clear();
    widget.api.invalidateCache();
    setState(() => _cals = widget.api.get('/calendars'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ajustes')),
        body: SelectionArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Row(children: [
              AppLogo(size: 56),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Agenda personal (${Api.appVersion})\nUniversidad + Trabajo en un solo lugar',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            Text('Horario fijo semanal (Trabajo / Clases)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text(
              'Define tus días y horas fijas de trabajo o clases. Aparecerán con título y detalles en tu calendario y el planificador automático evitará programar tareas encima.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  final changed = await showWeeklyScheduleModal(context, widget.api);
                  if (changed == true) {
                    setState(() => _wbs = widget.api.get('/weekly-blocks'));
                  }
                },
                icon: const Icon(Icons.work_history_outlined),
                label: const Text('Configurar mi horario semanal'),
              ),
            ),
            FutureBuilder<dynamic>(
              future: _wbs,
              builder: (c, s) {
                final list = (s.data as List?) ?? const [];
                if (list.isEmpty) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    children: [
                      for (final b in list)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            b['context'] == 'trabajo' ? Icons.work_outline : Icons.school_outlined,
                            color: contextColor(b['context']?.toString()),
                          ),
                          title: Text('${b['title']} (${formatDays(b['days'].toString())})'),
                          subtitle: Text('${b['start_time']} – ${b['end_time']}'),
                        ),
                    ],
                  ),
                );
              },
            ),
            const Divider(height: 32),
            Text('Calendarios externos (enlace .ics de Canvas / Google Calendar)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '💡 Tip para el calendario del trabajo: si en Google Calendar usas el enlace público, Google Workspace suele ocultar los nombres y mostrar solo "Busy / Ocupado". '
                'En la configuración de Google Calendar busca "Dirección secreta en formato iCal" (si tu empresa la habilita) o usa arriba la opción "Configurar mi horario semanal".',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 10),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre (ej. Canvas, Trabajo)')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _ctx,
              decoration: const InputDecoration(labelText: 'Contexto'),
              items: const ['universidad', 'trabajo', 'personal']
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (v) => setState(() => _ctx = v!),
            ),
            const SizedBox(height: 8),
            TextField(controller: _ics, decoration: const InputDecoration(labelText: 'Enlace .ics')),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _addCal,
              icon: const Icon(Icons.add),
              label: const Text('Añadir calendario'),
            ),
            FutureBuilder<dynamic>(
              future: _cals,
              builder: (c, s) => Column(children: [
                for (final cal in (s.data as List? ?? []))
                  ListTile(
                    title: Text(cal['name'].toString()),
                    subtitle: Text(cal['context'].toString()),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await widget.api.delete('/calendars/${cal['id']}');
                        widget.api.invalidateCache();
                        setState(() => _cals = widget.api.get('/calendars'));
                      },
                    ),
                  ),
              ]),
            ),
            const Divider(height: 32),
            Text('Servidor', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(controller: _url, decoration: const InputDecoration(labelText: 'URL del servidor')),
            const SizedBox(height: 8),
            TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                await Api.save(_url.text, _key.text);
                widget.onSaved();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Ajustes guardados')),
                  );
                }
              },
              child: const Text('Guardar conexión'),
            ),
          ]),
        ),
      );
}
