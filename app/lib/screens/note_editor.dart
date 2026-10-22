import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models/note_models.dart';
import '../theme.dart';

const _languages = ['plaintext', 'dart', 'python', 'javascript', 'java', 'cpp', 'sql', 'json', 'bash', 'xml', 'css'];
const _penColors = [Colors.black, Colors.red, Colors.blue, Colors.green, Colors.orange, Colors.white];
final _urlRe = RegExp(r'https?://[^\s]+');

/// Reduce la imagen a 1000 px de ancho como máximo y la devuelve en base64 (JPEG).
Map<String, dynamic> _prepareImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw Exception('Imagen no válida');
  final resized = decoded.width > 1000 ? img.copyResize(decoded, width: 1000) : decoded;
  final jpg = img.encodeJpg(resized, quality: 75);
  return {'b64': base64Encode(jpg), 'w': resized.width, 'h': resized.height};
}

class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, required this.api, this.noteId});
  final Api api;
  final int? noteId;
  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final _title = TextEditingController();
  final _tc = TransformationController();
  final _ctrls = <String, TextEditingController>{};
  List<NoteElement> _els = [];
  String _color = '#FFF59D';
  String _tags = '';
  bool _pinned = false;
  int? _id;
  bool _loading = true;
  bool _dirty = false;
  bool _failedOnce = false;
  String? _selected; // elemento seleccionado
  String? _editing; // texto/código en modo edición
  String? _drawing; // dibujo en modo lápiz
  Color _pen = Colors.black;
  Size _viewport = const Size(400, 600);
  Timer? _autosave;

  @override
  void initState() {
    super.initState();
    _id = widget.noteId;
    _load();
    _autosave = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_dirty) _save(silent: true);
    });
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _title.dispose();
    _tc.dispose();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_id != null) {
      try {
        final n = await widget.api.get('/notes/$_id') as Map;
        _title.text = n['title'] ?? '';
        _color = n['color'] ?? _color;
        _tags = n['tags'] ?? '';
        _pinned = (n['pinned'] ?? 0) == 1;
        _els = NoteElement.decodeList(n['canvas']?.toString());
        // Notas antiguas (solo texto): se convierten a un elemento de texto.
        if (_els.isEmpty && (n['body'] ?? '').toString().isNotEmpty) {
          _els = [
            NoteElement(id: NoteElement.newId(), type: 'text', w: 360, h: 200, data: {'text': n['body'], 'size': 16.0})
          ];
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo abrir: $e')));
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _touch() {
    _dirty = true;
    _failedOnce = false;
  }

  TextEditingController _ctrl(NoteElement e, String key) =>
      _ctrls.putIfAbsent('${e.id}:$key', () => TextEditingController(text: (e.data[key] ?? '').toString()));

  // ---------- guardar ----------
  Future<bool> _save({bool silent = false}) async {
    final empty = _title.text.trim().isEmpty && _els.isEmpty;
    if (_id == null && empty) return true;
    final plain = _els.map((e) => e.plainText).where((s) => s.isNotEmpty).join('\n');
    final body = {
      'title': _title.text.trim(),
      'body': plain,
      'tags': _tags,
      'canvas': NoteElement.encodeList(_els),
      'color': _color,
      'pinned': _pinned ? 1 : 0,
    };
    try {
      if (_id == null) {
        final r = await widget.api.post('/notes', body) as Map;
        _id = (r['id'] as num).toInt();
      } else {
        await widget.api.put('/notes/$_id', body);
      }
      _dirty = false;
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nota guardada'), duration: Duration(seconds: 1)));
      }
      return true;
    } catch (e) {
      if (!silent && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo guardar: $e')));
      return false;
    }
  }

  // ---------- agregar elementos ----------
  Offset _sceneCenter() {
    final p = _tc.toScene(Offset(_viewport.width / 2, _viewport.height / 2));
    final jitter = (_els.length % 6) * 18.0;
    return Offset(p.dx + jitter, p.dy + jitter);
  }

  void _add(String type, {double w = 260, double h = 140, Map<String, dynamic>? data}) {
    final c = _sceneCenter();
    final e = NoteElement(
      id: NoteElement.newId(),
      type: type,
      x: (c.dx - w / 2).clamp(0, 2900).toDouble(),
      y: (c.dy - h / 2).clamp(0, 2900).toDouble(),
      w: w,
      h: h,
      data: data,
    );
    setState(() {
      _els.add(e);
      _selected = e.id;
      _editing = (type == 'text' || type == 'code') ? e.id : null;
      _drawing = type == 'draw' ? e.id : null;
      _touch();
    });
  }

  Future<void> _addImage() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      final bytes = res?.files.first.bytes;
      if (bytes == null) return;
      final r = await compute(_prepareImage, bytes);
      final w = (r['w'] as int).toDouble(), h = (r['h'] as int).toDouble();
      final dw = w > 320 ? 320.0 : w;
      _add('image', w: dw, h: dw * h / w + 26, data: {'b64': r['b64']});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo añadir la imagen: $e')));
    }
  }

  Future<void> _editLink(NoteElement? e) async {
    final label = TextEditingController(text: (e?.data['label'] ?? '').toString());
    final url = TextEditingController(text: (e?.data['url'] ?? 'https://').toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hipervínculo'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: label, decoration: const InputDecoration(labelText: 'Texto visible')),
          const SizedBox(height: 8),
          TextField(controller: url, decoration: const InputDecoration(labelText: 'Dirección (https://...)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Aceptar')),
        ],
      ),
    );
    if (ok != true || url.text.trim().isEmpty) return;
    final data = {'label': label.text.trim().isEmpty ? url.text.trim() : label.text.trim(), 'url': url.text.trim()};
    if (e == null) {
      _add('link', w: 240, h: 64, data: data);
    } else {
      setState(() {
        e.data = data;
        _touch();
      });
    }
  }

  Future<void> _open(String url) async {
    final u = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (u == null || !await launchUrl(u, mode: LaunchMode.externalApplication)) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo abrir el enlace')));
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final bg = hexColor(_color);
    final dark = isDarkHex(_color);
    final fg = dark ? Colors.white : Colors.black87;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = _dirty ? await _save(silent: true) : true;
        if (!context.mounted) return;
        if (ok || _failedOnce) {
          Navigator.pop(context, true);
        } else {
          _failedOnce = true;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('No se pudo guardar. Pulsa atrás otra vez para salir sin guardar.')));
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          foregroundColor: fg,
          title: TextField(
            controller: _title,
            style: TextStyle(color: fg, fontSize: 20, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: 'Título',
              hintStyle: TextStyle(color: fg.withOpacity(0.5)),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            onChanged: (_) => _touch(),
          ),
          actions: [
            IconButton(
              tooltip: _pinned ? 'Desfijar' : 'Fijar',
              icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
              onPressed: () => setState(() {
                _pinned = !_pinned;
                _touch();
              }),
            ),
            IconButton(tooltip: 'Color', icon: const Icon(Icons.palette_outlined), onPressed: _pickColor),
            IconButton(tooltip: 'Etiquetas', icon: const Icon(Icons.sell_outlined), onPressed: _editTags),
            IconButton(tooltip: 'Guardar', icon: const Icon(Icons.check), onPressed: () => _save()),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(builder: (context, box) {
                _viewport = Size(box.maxWidth, box.maxHeight);
                final drawing = _drawing != null;
                return Stack(children: [
                  InteractiveViewer(
                    transformationController: _tc,
                    constrained: false,
                    minScale: 0.4,
                    maxScale: 2.5,
                    boundaryMargin: const EdgeInsets.all(300),
                    panEnabled: !drawing,
                    scaleEnabled: !drawing,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        FocusScope.of(context).unfocus();
                        setState(() {
                          _selected = null;
                          _editing = null;
                          _drawing = null;
                        });
                      },
                      child: SizedBox(
                        width: 3000,
                        height: 3000,
                        child: Stack(clipBehavior: Clip.none, children: [
                          Positioned.fill(child: CustomPaint(painter: _GridPainter(dark))),
                          for (final e in _els) _frame(e, dark),
                        ]),
                      ),
                    ),
                  ),
                  if (_drawing != null) Positioned(left: 0, right: 0, bottom: 76, child: _penBar()),
                ]);
              }),
        bottomNavigationBar: SafeArea(
          child: Container(
            color: Colors.black.withOpacity(dark ? 0.25 : 0.06),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Wrap(alignment: WrapAlignment.center, spacing: 4, children: [
              _tool(Icons.text_fields, 'Texto', () => _add('text', data: {'text': '', 'size': 16.0}), fg),
              _tool(Icons.code, 'Código', () => _add('code', w: 340, h: 200, data: {'text': '', 'lang': 'dart'}), fg),
              _tool(Icons.image_outlined, 'Imagen', _addImage, fg),
              _tool(Icons.link, 'Enlace', () => _editLink(null), fg),
              _tool(Icons.draw_outlined, 'Dibujo', () => _add('draw', w: 320, h: 240, data: {'strokes': <dynamic>[]}), fg),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tool(IconData i, String label, VoidCallback onTap, Color fg) => TextButton.icon(
        onPressed: onTap,
        icon: Icon(i, size: 20, color: fg),
        label: Text(label, style: TextStyle(color: fg)),
      );

  Future<void> _pickColor() async {
    final c = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Color de la nota'),
        content: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final h in notePalette)
            GestureDetector(
              onTap: () => Navigator.pop(c, h),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: hexColor(h),
                  shape: BoxShape.circle,
                  border: Border.all(color: h == _color ? Colors.indigo : Colors.black26, width: h == _color ? 3 : 1),
                ),
              ),
            ),
        ]),
      ),
    );
    if (c != null) {
      setState(() {
        _color = c;
        _touch();
      });
    }
  }

  Future<void> _editTags() async {
    final t = TextEditingController(text: _tags);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Etiquetas'),
        content: TextField(controller: t, decoration: const InputDecoration(hintText: 'estudio,proyecto,ideas')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Guardar')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _tags = t.text.replaceAll(' ', '').replaceAll('#', '');
        _touch();
      });
    }
  }

  Widget _penBar() => Center(
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final c in _penColors)
                GestureDetector(
                  onTap: () => setState(() => _pen = c),
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: _pen == c ? Colors.indigo : Colors.black26, width: _pen == c ? 3 : 1),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Deshacer trazo',
                icon: const Icon(Icons.undo),
                onPressed: () {
                  final e = _els.firstWhere((x) => x.id == _drawing);
                  final s = e.data['strokes'] as List;
                  if (s.isNotEmpty) {
                    setState(() {
                      s.removeLast();
                      _touch();
                    });
                  }
                },
              ),
              IconButton(
                tooltip: 'Listo',
                icon: const Icon(Icons.done),
                onPressed: () => setState(() => _drawing = null),
              ),
            ]),
          ),
        ),
      );

  // ---------- marco de cada elemento ----------
  double get _scale => _tc.value.getMaxScaleOnAxis();

  Widget _frame(NoteElement e, bool darkNote) {
    final selected = _selected == e.id;
    final isCode = e.type == 'code';
    final panelColor = isCode ? const Color(0xFF282C34) : Colors.white.withOpacity(darkNote ? 0.12 : 0.55);
    return Positioned(
      key: ValueKey(e.id),
      left: e.x,
      top: e.y,
      width: e.w,
      height: e.h,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: () => setState(() {
          _selected = e.id;
          // Ordena al frente
          _els.remove(e);
          _els.add(e);
        }),
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? brandSeed : Colors.black12, width: selected ? 2 : 1),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              _header(e, selected, isCode),
              Expanded(child: _content(e, selected)),
            ]),
          ),
          if (selected)
            Positioned(
              right: -8,
              bottom: -8,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() {
                  e.w = (e.w + d.delta.dx / _scale).clamp(110, 2000).toDouble();
                  e.h = (e.h + d.delta.dy / _scale).clamp(70, 2000).toDouble();
                  _touch();
                }),
                child: const CircleAvatar(radius: 11, backgroundColor: brandSeed, child: Icon(Icons.open_in_full, size: 12, color: Colors.white)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _header(NoteElement e, bool selected, bool isCode) {
    final fg = isCode ? Colors.white70 : Colors.black54;
    final actions = <Widget>[];
    if (selected) {
      if (e.type == 'text') {
        actions.addAll([
          _mini(Icons.text_decrease, 'Reducir', () => _setSize(e, -2), fg),
          _mini(Icons.text_increase, 'Aumentar', () => _setSize(e, 2), fg),
          _mini(Icons.format_bold, 'Negrita', () => setState(() {
                e.data['bold'] = !(e.data['bold'] == true);
                _touch();
              }), fg),
          _mini(_editing == e.id ? Icons.visibility : Icons.edit, _editing == e.id ? 'Ver' : 'Editar',
              () => setState(() => _editing = _editing == e.id ? null : e.id), fg),
        ]);
      } else if (e.type == 'code') {
        actions.add(DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _languages.contains(e.data['lang']) ? e.data['lang'] as String : 'plaintext',
            dropdownColor: const Color(0xFF282C34),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            isDense: true,
            items: [for (final l in _languages) DropdownMenuItem(value: l, child: Text(l))],
            onChanged: (v) => setState(() {
              e.data['lang'] = v;
              _touch();
            }),
          ),
        ));
        actions.add(_mini(_editing == e.id ? Icons.visibility : Icons.edit, _editing == e.id ? 'Ver' : 'Editar',
            () => setState(() => _editing = _editing == e.id ? null : e.id), fg));
      } else if (e.type == 'link') {
        actions.add(_mini(Icons.edit, 'Editar enlace', () => _editLink(e), fg));
      } else if (e.type == 'draw') {
        actions.add(_mini(Icons.brush, 'Dibujar', () => setState(() => _drawing = _drawing == e.id ? null : e.id), fg));
      }
      actions.add(_mini(Icons.delete_outline, 'Eliminar', () => _confirmDelete(e), Colors.redAccent));
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => setState(() => _selected = e.id),
      onPanUpdate: (d) => setState(() {
        e.x = (e.x + d.delta.dx / _scale).clamp(0, 2950).toDouble();
        e.y = (e.y + d.delta.dy / _scale).clamp(0, 2950).toDouble();
        _touch();
      }),
      child: Container(
        height: 28,
        color: isCode ? Colors.black26 : Colors.black.withOpacity(0.06),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Icon(Icons.drag_indicator, size: 16, color: fg),
          const Spacer(),
          ...actions,
        ]),
      ),
    );
  }

  Widget _mini(IconData i, String tip, VoidCallback onTap, Color c) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Tooltip(message: tip, child: Padding(padding: const EdgeInsets.all(4), child: Icon(i, size: 16, color: c))),
      );

  void _setSize(NoteElement e, double d) => setState(() {
        e.data['size'] = (((e.data['size'] as num?)?.toDouble() ?? 16.0) + d).clamp(10, 72).toDouble();
        _touch();
      });

  void _confirmDelete(NoteElement e) => setState(() {
        _els.remove(e);
        _selected = _editing = _drawing = null;
        _touch();
      });

  // ---------- contenido ----------
  Widget _content(NoteElement e, bool selected) {
    switch (e.type) {
      case 'text':
        return _textBody(e);
      case 'code':
        return _codeBody(e);
      case 'image':
        return Padding(
          padding: const EdgeInsets.all(4),
          child: Image.memory(base64Decode((e.data['b64'] ?? '').toString()), fit: BoxFit.contain, gaplessPlayback: true),
        );
      case 'link':
        final url = (e.data['url'] ?? '').toString();
        return InkWell(
          onTap: () => _open(url),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              const Icon(Icons.link, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text((e.data['label'] ?? url).toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline, fontSize: 15)),
              ),
            ]),
          ),
        );
      case 'draw':
        return _drawBody(e);
    }
    return const SizedBox();
  }

  Widget _textBody(NoteElement e) {
    final size = (e.data['size'] as num?)?.toDouble() ?? 16.0;
    final style = TextStyle(fontSize: size, color: Colors.black87, fontWeight: e.data['bold'] == true ? FontWeight.bold : FontWeight.normal);
    final text = (e.data['text'] ?? '').toString();
    final hasLinks = _urlRe.hasMatch(text);
    if (_editing != e.id && hasLinks) {
      // Vista con hipervínculos pulsables
      final spans = <InlineSpan>[];
      var last = 0;
      for (final m in _urlRe.allMatches(text)) {
        if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
        final url = m.group(0)!;
        spans.add(TextSpan(
          text: url,
          style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()..onTap = () => _open(url),
        ));
        last = m.end;
      }
      if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => setState(() => _editing = e.id),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Text.rich(TextSpan(style: style, children: spans)),
        ),
      );
    }
    return TextField(
      controller: _ctrl(e, 'text'),
      style: style,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      decoration: const InputDecoration(
        hintText: 'Escribe aquí…',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.all(8),
      ),
      onTap: () => setState(() {
        _selected = e.id;
        _editing = e.id;
      }),
      onChanged: (v) {
        e.data['text'] = v;
        _touch();
      },
    );
  }

  Widget _codeBody(NoteElement e) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFFABB2BF), height: 1.35);
    final code = (e.data['text'] ?? '').toString();
    final lang = (e.data['lang'] ?? 'plaintext').toString();
    if (_editing != e.id && code.isNotEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => setState(() => _editing = e.id),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: HighlightView(
              code,
              language: lang,
              theme: atomOneDarkTheme,
              padding: const EdgeInsets.all(10),
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35),
            ),
          ),
        ),
      );
    }
    return TextField(
      controller: _ctrl(e, 'text'),
      style: mono,
      maxLines: null,
      expands: true,
      cursorColor: Colors.white,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      enableSuggestions: false,
      autocorrect: false,
      decoration: const InputDecoration(
        hintText: '// pega o escribe tu código',
        hintStyle: TextStyle(color: Colors.white24),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.all(10),
      ),
      onTap: () => setState(() {
        _selected = e.id;
        _editing = e.id;
      }),
      onChanged: (v) {
        e.data['text'] = v;
        _touch();
      },
    );
  }

  Widget _drawBody(NoteElement e) {
    final strokes = [for (final s in (e.data['strokes'] as List? ?? const [])) Stroke.fromJson(Map<String, dynamic>.from(s as Map))];
    final active = _drawing == e.id;
    final painter = CustomPaint(painter: _StrokePainter(strokes), child: const SizedBox.expand());
    if (!active) return painter;
    return GestureDetector(
      onPanStart: (d) => setState(() {
        (e.data['strokes'] as List).add(Stroke(_pen.value, _pen == Colors.white ? 10 : 3, [d.localPosition.dx, d.localPosition.dy]).toJson());
        _touch();
      }),
      onPanUpdate: (d) => setState(() {
        final list = e.data['strokes'] as List;
        if (list.isEmpty) return;
        ((list.last as Map)['p'] as List).addAll([d.localPosition.dx, d.localPosition.dy]);
        _touch();
      }),
      child: MouseRegion(cursor: SystemMouseCursors.precise, child: painter),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = (dark ? Colors.white : Colors.black).withOpacity(0.07);
    for (double x = 0; x < size.width; x += 40) {
      for (double y = 0; y < size.height; y += 40) {
        canvas.drawCircle(Offset(x, y), 1.4, p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.dark != dark;
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes);
  final List<Stroke> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = Color(s.color)
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i + 1 < s.points.length; i += 2) {
        final o = Offset(s.points[i], s.points[i + 1]);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      if (s.points.length == 2) path.lineTo(s.points[0] + 0.1, s.points[1]);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
