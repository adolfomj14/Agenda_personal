import 'package:flutter/material.dart';
import '../api.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.api});
  final Api api;
  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  String _q = '';
  late Future<dynamic> _f = _load();
  Future<dynamic> _load() => widget.api.get('/notes${_q.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(_q)}'}');
  void _refresh() => setState(() => _f = _load());

  Future<void> _edit([Map? note]) async {
    final title = TextEditingController(text: note?['title'] ?? '');
    final body = TextEditingController(text: note?['body'] ?? '');
    final tags = TextEditingController(text: note?['tags'] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(note == null ? 'Nueva nota' : 'Editar nota'),
        content: SizedBox(
          width: 500,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Título')),
            TextField(controller: body, maxLines: 8, decoration: const InputDecoration(labelText: 'Contenido')),
            TextField(controller: tags, decoration: const InputDecoration(labelText: 'Etiquetas (separadas por coma)')),
          ]),
        ),
        actions: [
          if (note != null)
            TextButton(onPressed: () async { await widget.api.delete('/notes/${note['id']}'); if (c.mounted) Navigator.pop(c, true); }, child: const Text('Eliminar')),
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) return;
    final data = {'title': title.text, 'body': body.text, 'tags': tags.text.replaceAll(' ', '')};
    if (note == null) {
      if (title.text.isNotEmpty || body.text.isNotEmpty) await widget.api.post('/notes', data);
    } else if (title.text.isNotEmpty || body.text.isNotEmpty) {
      await widget.api.put('/notes/${note['id']}', data);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(
            decoration: const InputDecoration(hintText: 'Buscar notas…', border: InputBorder.none, prefixIcon: Icon(Icons.search)),
            onSubmitted: (v) { _q = v; _refresh(); },
          ),
        ),
        floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
        body: FutureBuilder<dynamic>(
          future: _f,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${s.error}')));
            final notes = s.data as List;
            if (notes.isEmpty) return const Center(child: Text('Sin notas'));
            return GridView.extent(
              maxCrossAxisExtent: 320,
              padding: const EdgeInsets.all(8),
              children: [
                for (final n in notes)
                  Card(
                    child: InkWell(
                      onTap: () => _edit(n),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(n['title'], style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Expanded(child: Text(n['body'], overflow: TextOverflow.fade)),
                          if ((n['tags'] as String).isNotEmpty) Text('#${(n['tags'] as String).split(',').join(' #')}', style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
}
