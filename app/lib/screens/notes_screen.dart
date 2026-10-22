import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'note_editor.dart';

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

  Future<void> _open([int? id]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => NoteEditor(api: widget.api, noteId: id)));
    if (mounted) _refresh();
  }

  Future<void> _delete(Map n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Eliminar nota'),
        content: Text('¿Eliminar "${(n['title'] as String).isEmpty ? 'Sin título' : n['title']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) {
      await widget.api.delete('/notes/${n['id']}');
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: SearchBar(
            hintText: 'Buscar notas…',
            elevation: const WidgetStatePropertyAll(0),
            leading: const Icon(Icons.search),
            onSubmitted: (v) {
              _q = v;
              _refresh();
            },
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _open(),
          icon: const Icon(Icons.add),
          label: const Text('Nota'),
        ),
        body: FutureBuilder<dynamic>(
          future: _f,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (s.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${s.error}')));
            final notes = s.data as List;
            if (notes.isEmpty) {
              return const Center(child: Text('Aún no tienes notas.\nCrea la primera con el botón +', textAlign: TextAlign.center));
            }
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 260,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.95,
              ),
              itemCount: notes.length,
              itemBuilder: (c, i) => _card(notes[i] as Map),
            );
          },
        ),
      );

  Widget _card(Map n) {
    final color = (n['color'] ?? '#FFF59D').toString();
    final dark = isDarkHex(color);
    final fg = dark ? Colors.white : Colors.black87;
    final title = (n['title'] ?? '').toString();
    final tags = (n['tags'] ?? '').toString().split(',').where((t) => t.isNotEmpty).toList();
    return Material(
      color: hexColor(color),
      borderRadius: BorderRadius.circular(16),
      elevation: 2,
      shadowColor: Colors.black38,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open((n['id'] as num).toInt()),
        onLongPress: () => _delete(n),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title.isEmpty ? 'Sin título' : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              if ((n['pinned'] ?? 0) == 1) Icon(Icons.push_pin, size: 18, color: fg),
              PopupMenuButton<String>(
                iconSize: 18,
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_vert, size: 18, color: fg),
                onSelected: (_) => _delete(n),
                itemBuilder: (_) => const [PopupMenuItem(value: 'del', child: Text('Eliminar'))],
              ),
            ]),
            const SizedBox(height: 6),
            Expanded(
              child: Text((n['body'] ?? '').toString(),
                  overflow: TextOverflow.fade, style: TextStyle(color: fg.withOpacity(0.85), fontSize: 13.5)),
            ),
            if (((n['canvas_size'] ?? 0) as num) > 2000)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Icon(Icons.image_outlined, size: 14, color: fg.withOpacity(0.7)),
                  const SizedBox(width: 4),
                  Text('con contenido multimedia', style: TextStyle(color: fg.withOpacity(0.7), fontSize: 11)),
                ]),
              ),
            if (tags.isNotEmpty)
              Wrap(spacing: 4, runSpacing: 2, children: [
                for (final t in tags.take(3))
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: fg.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text('#$t', style: TextStyle(color: fg, fontSize: 11)),
                  ),
              ]),
          ]),
        ),
      ),
    );
  }
}
