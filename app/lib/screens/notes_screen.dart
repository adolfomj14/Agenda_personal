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
  String _selectedTag = '';
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;
  bool _syncing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  void _initLoad() {
    final cached = widget.api.peekCache('/notes');
    if (cached is List) {
      _notes = [for (final n in cached) Map<String, dynamic>.from(n as Map)];
      _loading = false;
    }
    _refresh(silent: !_loading);
  }

  Future<void> _refresh({bool silent = false}) async {
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
      final path = '/notes${_q.isEmpty ? '' : '?q=${Uri.encodeQueryComponent(_q)}'}';
      final res = await widget.api.get(path) as List;
      if (!mounted) return;
      final list = [for (final n in res) Map<String, dynamic>.from(n as Map)];
      if (_q.isEmpty) {
        widget.api.setCache('/notes', list);
      }
      setState(() {
        _notes = list;
        _loading = false;
        _syncing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _syncing = false;
        if (_notes.isEmpty) _error = '$e';
      });
    }
  }

  Future<void> _open([int? id]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => NoteEditor(api: widget.api, noteId: id)));
    if (mounted) _refresh(silent: _notes.isNotEmpty);
  }

  Future<void> _togglePin(Map<String, dynamic> n) async {
    final id = (n['id'] as num).toInt();
    final newPin = ((n['pinned'] ?? 0) == 1) ? 0 : 1;
    setState(() {
      n['pinned'] = newPin;
      _notes.sort((a, b) => ((b['pinned'] ?? 0) as int).compareTo((a['pinned'] ?? 0) as int));
    });
    widget.api.setCache('/notes', _notes);
    try {
      final full = await widget.api.get('/notes/$id') as Map;
      await widget.api.put('/notes/$id', {
        'title': full['title'] ?? '',
        'body': full['body'] ?? '',
        'tags': full['tags'] ?? '',
        'task_id': full['task_id'],
        'canvas': full['canvas'] ?? '[]',
        'color': full['color'] ?? '#FFF59D',
        'pinned': newPin,
      });
      await _refresh(silent: true);
    } catch (_) {}
  }

  Future<void> _duplicate(Map<String, dynamic> n) async {
    final id = (n['id'] as num).toInt();
    try {
      final full = await widget.api.get('/notes/$id') as Map;
      await widget.api.post('/notes', {
        'title': '${full['title'] ?? 'Nota'} (copia)',
        'body': full['body'] ?? '',
        'tags': full['tags'] ?? '',
        'task_id': full['task_id'],
        'canvas': full['canvas'] ?? '[]',
        'color': full['color'] ?? '#FFF59D',
        'pinned': 0,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nota duplicada'), duration: Duration(seconds: 1)),
        );
      }
      await _refresh(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo duplicar: $e')));
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Eliminar nota'),
        content: Text('¿Eliminar "${(n['title'] ?? '').toString().isEmpty ? 'Sin título' : n['title']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) {
      final id = (n['id'] as num).toInt();
      setState(() => _notes.removeWhere((x) => (x['id'] as num).toInt() == id));
      widget.api.setCache('/notes', _notes);
      await widget.api.delete('/notes/$id');
      await _refresh(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allTags = <String>{};
    for (final n in _notes) {
      for (final t in (n['tags'] ?? '').toString().split(',')) {
        if (t.trim().isNotEmpty) allTags.add(t.trim());
      }
    }

    final queryLower = _q.trim().toLowerCase();
    final filtered = _notes.where((n) {
      if (_selectedTag.isNotEmpty) {
        final tags = (n['tags'] ?? '').toString().split(',').map((s) => s.trim()).toSet();
        if (!tags.contains(_selectedTag)) return false;
      }
      if (queryLower.isNotEmpty) {
        final title = (n['title'] ?? '').toString().toLowerCase();
        final body = (n['body'] ?? '').toString().toLowerCase();
        final tags = (n['tags'] ?? '').toString().toLowerCase();
        if (!title.contains(queryLower) && !body.contains(queryLower) && !tags.contains(queryLower)) {
          return false;
        }
      }
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: SearchBar(
          hintText: 'Buscar en tus notas…',
          elevation: const WidgetStatePropertyAll(0),
          leading: const Icon(Icons.search),
          onChanged: (v) => setState(() => _q = v),
          onSubmitted: (v) {
            _q = v;
            _refresh(silent: _notes.isNotEmpty);
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizar notas',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(silent: _notes.isNotEmpty),
          ),
        ],
        bottom: _syncing && _notes.isNotEmpty
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(),
        icon: const Icon(Icons.add),
        label: const Text('Nueva nota'),
      ),
      body: _loading && _notes.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _notes.isEmpty
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
              : Column(
                  children: [
                    if (allTags.isNotEmpty)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                        child: Row(
                          children: [
                            ChoiceChip(
                              label: const Text('Todas'),
                              selected: _selectedTag.isEmpty,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => setState(() => _selectedTag = ''),
                            ),
                            const SizedBox(width: 6),
                            for (final tag in allTags) ...[
                              ChoiceChip(
                                label: Text('#$tag'),
                                selected: _selectedTag == tag,
                                visualDensity: VisualDensity.compact,
                                onSelected: (v) => setState(() => _selectedTag = v ? tag : ''),
                              ),
                              const SizedBox(width: 6),
                            ],
                          ],
                        ),
                      ),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                _notes.isEmpty
                                    ? 'Aún no tienes notas.\nCrea la primera con el botón "Nueva nota".'
                                    : 'No hay notas que coincidan con este filtro.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 88),
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 260,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.95,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (c, i) => _card(filtered[i]),
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _card(Map<String, dynamic> n) {
    final color = (n['color'] ?? '#FFF59D').toString();
    final dark = isDarkHex(color);
    final fg = dark ? Colors.white : Colors.black87;
    final title = (n['title'] ?? '').toString();
    final pinned = (n['pinned'] ?? 0) == 1;
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
                child: Text(
                  title.isEmpty ? 'Sin título' : title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              if (pinned) Icon(Icons.push_pin, size: 18, color: fg),
              PopupMenuButton<String>(
                iconSize: 18,
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_vert, size: 18, color: fg),
                onSelected: (action) {
                  if (action == 'pin') _togglePin(n);
                  if (action == 'dup') _duplicate(n);
                  if (action == 'del') _delete(n);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'pin', child: Text(pinned ? 'Desfijar' : 'Fijar arriba')),
                  const PopupMenuItem(value: 'dup', child: Text('Duplicar nota')),
                  const PopupMenuItem(value: 'del', child: Text('Eliminar')),
                ],
              ),
            ]),
            const SizedBox(height: 6),
            Expanded(
              child: Text(
                (n['body'] ?? '').toString(),
                overflow: TextOverflow.fade,
                style: TextStyle(color: fg.withOpacity(0.85), fontSize: 13.5),
              ),
            ),
            if (((n['canvas_size'] ?? 0) as num) > 2000)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Icon(Icons.brush_outlined, size: 14, color: fg.withOpacity(0.7)),
                  const SizedBox(width: 4),
                  Text('Lienzo / multimedia', style: TextStyle(color: fg.withOpacity(0.7), fontSize: 11)),
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
