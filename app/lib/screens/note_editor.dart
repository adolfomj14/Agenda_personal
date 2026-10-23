import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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

const _penColors = [
  Colors.black,
  Color(0xFFE53935),
  Color(0xFF1E88E5),
  Color(0xFF2E7D32),
  Color(0xFFFB8C00),
  Color(0xFF8E24AA),
  Color(0xFF00897B),
  Color(0xFFFFEB3B),
  Colors.white,
];

const _textColors = [
  Color(0xDD000000),
  Color(0xFF1565C0),
  Color(0xFFC62828),
  Color(0xFF2E7D32),
  Color(0xFF6A1B9A),
  Color(0xFFEF6C00),
  Color(0xFF37474F),
  Colors.white,
];

const _fontFamilies = <String, String?>{
  'Sans': null,
  'Serif': 'serif',
  'Mono': 'monospace',
  'Casual': 'cursive',
};

final _urlRe = RegExp(r'https?://[^\s]+');
final _numListRe = RegExp(r'^(\s*)(\d+)\.\s(.*)$');
final _bulletListRe = RegExp(r'^(\s*)([•\-*])\s(.*)$');
final _checkListRe = RegExp(r'^(\s*)([☐☑])\s(.*)$');

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
  final _prevTexts = <String, String>{};
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
  double _penWidth = 3.5;
  bool _eraser = false;
  bool _highlighter = false;
  int? _activePointer;
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
        if (_els.isEmpty && (n['body'] ?? '').toString().isNotEmpty) {
          _els = [
            NoteElement(id: NoteElement.newId(), type: 'text', w: 340, h: 220, data: {'text': n['body'], 'size': 16.0})
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

  TextEditingController _ctrl(NoteElement e, String key) {
    final k = '${e.id}:$key';
    return _ctrls.putIfAbsent(k, () {
      final initial = (e.data[key] ?? '').toString();
      _prevTexts[k] = initial;
      return TextEditingController(text: initial);
    });
  }

  NoteElement? get _selectedElement {
    if (_selected == null) return null;
    for (final e in _els) {
      if (e.id == _selected) return e;
    }
    return null;
  }

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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Nota guardada'), duration: Duration(seconds: 1)));
      }
      return true;
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo guardar: $e')));
      }
      return false;
    }
  }

  // ---------- agregar elementos ----------
  Offset _sceneCenter() {
    final p = _tc.toScene(Offset(_viewport.width / 2, _viewport.height / 2));
    final jitter = (_els.length % 6) * 16.0;
    return Offset(p.dx + jitter, p.dy + jitter);
  }

  void _add(String type, {double w = 280, double h = 160, Map<String, dynamic>? data}) {
    final c = _sceneCenter();
    final maxW = math.max(260.0, _viewport.width - 28);
    final actualW = type == 'draw' ? math.min(520.0, maxW) : math.min(w, maxW);
    final e = NoteElement(
      id: NoteElement.newId(),
      type: type,
      x: (c.dx - actualW / 2).clamp(8, 2850).toDouble(),
      y: (c.dy - h / 2).clamp(8, 2850).toDouble(),
      w: actualW,
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
      _add('image', w: dw, h: dw * h / w + 32, data: {'b64': r['b64']});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo añadir la imagen: $e')));
      }
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
      _add('link', w: 250, h: 70, data: data);
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo abrir el enlace')));
      }
    }
  }

  // ---------- Formato de texto y listas ----------
  void _applyTextPreset(NoteElement e, String preset) {
    setState(() {
      e.data['preset'] = preset;
      switch (preset) {
        case 'h1':
          e.data['size'] = 24.0;
          e.data['bold'] = true;
          e.data['italic'] = false;
          e.data['quote'] = false;
          break;
        case 'h2':
          e.data['size'] = 19.0;
          e.data['bold'] = true;
          e.data['italic'] = false;
          e.data['quote'] = false;
          break;
        case 'quote':
          e.data['size'] = 16.0;
          e.data['bold'] = false;
          e.data['italic'] = true;
          e.data['quote'] = true;
          break;
        case 'small':
          e.data['size'] = 13.0;
          e.data['bold'] = false;
          e.data['quote'] = false;
          break;
        default: // body
          e.data['size'] = 16.0;
          e.data['bold'] = false;
          e.data['italic'] = false;
          e.data['quote'] = false;
      }
      _touch();
    });
  }

  /// Inserta o alterna prefijos de lista (• , 1. , ☐ / ☑) sobre la línea actual o las líneas seleccionadas.
  void _toggleListPrefix(NoteElement e, String listKind) {
    final ctrl = _ctrl(e, 'text');
    final text = ctrl.text;
    final sel = ctrl.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;

    final lineStart = text.lastIndexOf('\n', math.max(0, start - 1)) + 1;
    final nextNl = text.indexOf('\n', end);
    final lineEnd = nextNl == -1 ? text.length : nextNl;

    final block = text.substring(lineStart, lineEnd);
    final lines = block.split('\n');
    final transformed = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final bMatch = _bulletListRe.firstMatch(line);
      final nMatch = _numListRe.firstMatch(line);
      final cMatch = _checkListRe.firstMatch(line);

      if (listKind == 'bullet') {
        if (bMatch != null) {
          transformed.add('${bMatch.group(1)}${bMatch.group(3)}');
        } else if (nMatch != null) {
          transformed.add('${nMatch.group(1)}• ${nMatch.group(3)}');
        } else if (cMatch != null) {
          transformed.add('${cMatch.group(1)}• ${cMatch.group(3)}');
        } else {
          transformed.add('• $line');
        }
      } else if (listKind == 'number') {
        final numPrefix = '${i + 1}. ';
        if (nMatch != null) {
          transformed.add('${nMatch.group(1)}${nMatch.group(3)}');
        } else if (bMatch != null) {
          transformed.add('${bMatch.group(1)}$numPrefix${bMatch.group(3)}');
        } else if (cMatch != null) {
          transformed.add('${cMatch.group(1)}$numPrefix${cMatch.group(3)}');
        } else {
          transformed.add('$numPrefix$line');
        }
      } else if (listKind == 'check') {
        if (cMatch != null) {
          final currentBox = cMatch.group(2);
          if (currentBox == '☐') {
            transformed.add('${cMatch.group(1)}☑ ${cMatch.group(3)}');
          } else {
            transformed.add('${cMatch.group(1)}${cMatch.group(3)}');
          }
        } else if (bMatch != null) {
          transformed.add('${bMatch.group(1)}☐ ${bMatch.group(3)}');
        } else if (nMatch != null) {
          transformed.add('${nMatch.group(1)}☐ ${nMatch.group(3)}');
        } else {
          transformed.add('☐ $line');
        }
      }
    }

    final replacement = transformed.join('\n');
    final newText = text.replaceRange(lineStart, lineEnd, replacement);
    final newCursor = lineStart + replacement.length;
    _prevTexts['${e.id}:text'] = newText;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor.clamp(0, newText.length)),
    );
    setState(() {
      e.data['text'] = newText;
      _editing = e.id;
      _touch();
    });
  }

  void _indentLine(NoteElement e, bool increase) {
    final ctrl = _ctrl(e, 'text');
    final text = ctrl.text;
    final sel = ctrl.selection;
    final start = sel.isValid ? sel.start : text.length;
    final lineStart = text.lastIndexOf('\n', math.max(0, start - 1)) + 1;
    String newText;
    int delta = 0;
    if (increase) {
      newText = text.replaceRange(lineStart, lineStart, '  ');
      delta = 2;
    } else if (text.substring(lineStart).startsWith('  ')) {
      newText = text.replaceRange(lineStart, lineStart + 2, '');
      delta = -2;
    } else {
      return;
    }
    _prevTexts['${e.id}:text'] = newText;
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: (start + delta).clamp(0, newText.length)),
    );
    setState(() {
      e.data['text'] = newText;
      _touch();
    });
  }

  /// Auto-continúa listas (• , 1. , ☐ ) cuando el usuario presiona Enter.
  void _handleTextChanged(NoteElement e, String v) {
    final key = '${e.id}:text';
    final prev = _prevTexts[key] ?? '';
    final ctrl = _ctrl(e, 'text');
    final cursor = ctrl.selection.baseOffset;

    if (v.length == prev.length + 1 && cursor > 0 && v[cursor - 1] == '\n') {
      final beforeEnter = v.substring(0, cursor - 1);
      final prevLineStart = beforeEnter.lastIndexOf('\n') + 1;
      final prevLine = beforeEnter.substring(prevLineStart);

      String? continuation;
      bool emptyItem = false;

      final bMatch = _bulletListRe.firstMatch(prevLine);
      final nMatch = _numListRe.firstMatch(prevLine);
      final cMatch = _checkListRe.firstMatch(prevLine);

      if (bMatch != null) {
        if (bMatch.group(3)!.trim().isEmpty) {
          emptyItem = true;
        } else {
          continuation = '${bMatch.group(1)}${bMatch.group(2)} ';
        }
      } else if (nMatch != null) {
        if (nMatch.group(3)!.trim().isEmpty) {
          emptyItem = true;
        } else {
          final nextNum = (int.tryParse(nMatch.group(2)!) ?? 1) + 1;
          continuation = '${nMatch.group(1)}$nextNum. ';
        }
      } else if (cMatch != null) {
        if (cMatch.group(3)!.trim().isEmpty) {
          emptyItem = true;
        } else {
          continuation = '${cMatch.group(1)}☐ ';
        }
      }

      if (emptyItem) {
        final cleaned = v.replaceRange(prevLineStart, cursor, '');
        _prevTexts[key] = cleaned;
        ctrl.value = TextEditingValue(
          text: cleaned,
          selection: TextSelection.collapsed(offset: prevLineStart.clamp(0, cleaned.length)),
        );
        e.data['text'] = cleaned;
        _touch();
        return;
      } else if (continuation != null) {
        final updated = v.replaceRange(cursor, cursor, continuation);
        final newOffset = cursor + continuation.length;
        _prevTexts[key] = updated;
        ctrl.value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: newOffset.clamp(0, updated.length)),
        );
        e.data['text'] = updated;
        _touch();
        return;
      }
    }

    _prevTexts[key] = v;
    e.data['text'] = v;
    _touch();
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final bg = hexColor(_color);
    final dark = isDarkHex(_color);
    final fg = dark ? Colors.white : Colors.black87;
    final selEl = _selectedElement;
    final showTextBar = selEl != null && selEl.type == 'text' && _drawing == null;

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
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No se pudo guardar. Pulsa atrás otra vez para salir sin guardar.')));
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
              hintText: 'Título de la nota',
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
                        if (!drawing) {
                          setState(() {
                            _selected = null;
                            _editing = null;
                          });
                        }
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
                  if (_drawing != null) Positioned(left: 8, right: 8, bottom: 12, child: _penBar()),
                  if (showTextBar) Positioned(left: 8, right: 8, bottom: 12, child: _textFormatBar(selEl)),
                ]);
              }),
        bottomNavigationBar: SafeArea(
          child: Container(
            color: Colors.black.withOpacity(dark ? 0.25 : 0.06),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _tool(Icons.text_fields, 'Texto', () => _add('text', data: {'text': '', 'size': 16.0}), fg),
                _tool(
                  Icons.format_list_bulleted,
                  'Lista',
                  () => _add('text', w: 280, h: 180, data: {'text': '• ', 'size': 16.0}),
                  fg,
                ),
                _tool(
                  Icons.checklist_rtl,
                  'Checklist',
                  () => _add('text', w: 280, h: 180, data: {'text': '☐ ', 'size': 16.0}),
                  fg,
                ),
                _tool(Icons.draw_outlined, 'Dibujo', () {
                  // Si ya hay un bloque de dibujo seleccionado, activar lápiz en él; si no, crear uno amplio.
                  final sel = _selectedElement;
                  if (sel != null && sel.type == 'draw') {
                    setState(() => _drawing = _drawing == sel.id ? null : sel.id);
                  } else {
                    _add('draw', w: 360, h: 320, data: {'strokes': <dynamic>[]});
                  }
                }, fg),
                _tool(Icons.code, 'Código', () => _add('code', w: 340, h: 200, data: {'text': '', 'lang': 'dart'}), fg),
                _tool(Icons.image_outlined, 'Imagen', _addImage, fg),
                _tool(Icons.link, 'Enlace', () => _editLink(null), fg),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tool(IconData i, String label, VoidCallback onTap, Color fg) => TextButton.icon(
        onPressed: onTap,
        icon: Icon(i, size: 20, color: fg),
        label: Text(label, style: TextStyle(color: fg, fontSize: 13.5)),
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

  // ---------- Barra flotante de formato de texto ----------
  Widget _textFormatBar(NoteElement e) {
    final preset = (e.data['preset'] ?? 'body').toString();
    final fontName = (e.data['font'] ?? 'Sans').toString();
    final bold = e.data['bold'] == true;
    final italic = e.data['italic'] == true;
    final underline = e.data['underline'] == true;
    final strike = e.data['strike'] == true;
    final align = (e.data['align'] ?? 'left').toString();
    final currentColor = (e.data['color'] as num?)?.toInt() ?? 0xDD000000;

    return Center(
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // Selector de tipo de texto (Título, Subtítulo, Normal, Cita, Pequeño)
              PopupMenuButton<String>(
                tooltip: 'Tipo de texto',
                initialValue: preset,
                onSelected: (v) => _applyTextPreset(e, v),
                itemBuilder: (c) => const [
                  PopupMenuItem(
                    value: 'h1',
                    child: Text('Título grande', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ),
                  PopupMenuItem(
                    value: 'h2',
                    child: Text('Subtítulo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  PopupMenuItem(
                    value: 'body',
                    child: Text('Párrafo normal', style: TextStyle(fontSize: 14)),
                  ),
                  PopupMenuItem(
                    value: 'quote',
                    child: Text('❝ Cita destacada', style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic)),
                  ),
                  PopupMenuItem(
                    value: 'small',
                    child: Text('Nota pequeña', style: TextStyle(fontSize: 12)),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: brandSeed.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.format_size, size: 16, color: brandSeed),
                    const SizedBox(width: 4),
                    Text(
                      switch (preset) {
                        'h1' => 'Título',
                        'h2' => 'Subtítulo',
                        'quote' => 'Cita',
                        'small' => 'Pequeño',
                        _ => 'Párrafo',
                      },
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: brandSeed),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 16, color: brandSeed),
                  ]),
                ),
              ),
              const SizedBox(width: 6),
              // Selector de fuente
              PopupMenuButton<String>(
                tooltip: 'Tipografía / Fuente',
                initialValue: _fontFamilies.containsKey(fontName) ? fontName : 'Sans',
                onSelected: (v) => setState(() {
                  e.data['font'] = v;
                  _touch();
                }),
                itemBuilder: (c) => [
                  for (final entry in _fontFamilies.entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: Text(entry.key, style: TextStyle(fontFamily: entry.value, fontSize: 14)),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black26),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(fontName, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
                    const Icon(Icons.arrow_drop_down, size: 16),
                  ]),
                ),
              ),
              const SizedBox(width: 4),
              _fmtBtn(Icons.text_decrease, 'Reducir letra', false, () => _setSize(e, -2)),
              _fmtBtn(Icons.text_increase, 'Aumentar letra', false, () => _setSize(e, 2)),
              const VerticalDivider(width: 8),
              _fmtBtn(Icons.format_bold, 'Negrita', bold, () => setState(() {
                    e.data['bold'] = !bold;
                    _touch();
                  })),
              _fmtBtn(Icons.format_italic, 'Cursiva', italic, () => setState(() {
                    e.data['italic'] = !italic;
                    _touch();
                  })),
              _fmtBtn(Icons.format_underlined, 'Subrayado', underline, () => setState(() {
                    e.data['underline'] = !underline;
                    _touch();
                  })),
              _fmtBtn(Icons.format_strikethrough, 'Tachado', strike, () => setState(() {
                    e.data['strike'] = !strike;
                    _touch();
                  })),
              const VerticalDivider(width: 8),
              // Viñetas, lista numerada, checklist y sangría
              _fmtBtn(Icons.format_list_bulleted, 'Viñetas (•)', false, () => _toggleListPrefix(e, 'bullet')),
              _fmtBtn(Icons.format_list_numbered, 'Lista numerada (1.)', false, () => _toggleListPrefix(e, 'number')),
              _fmtBtn(Icons.check_box_outlined, 'Casilla de tarea (☐/☑)', false, () => _toggleListPrefix(e, 'check')),
              _fmtBtn(Icons.format_indent_increase, 'Aumentar sangría', false, () => _indentLine(e, true)),
              _fmtBtn(Icons.format_indent_decrease, 'Reducir sangría', false, () => _indentLine(e, false)),
              const VerticalDivider(width: 8),
              _fmtBtn(
                align == 'center'
                    ? Icons.format_align_center
                    : align == 'right'
                        ? Icons.format_align_right
                        : Icons.format_align_left,
                'Alineación',
                align != 'left',
                () => setState(() {
                  e.data['align'] = align == 'left'
                      ? 'center'
                      : align == 'center'
                          ? 'right'
                          : 'left';
                  _touch();
                }),
              ),
              const SizedBox(width: 4),
              // Colores de texto
              for (final c in _textColors)
                GestureDetector(
                  onTap: () => setState(() {
                    e.data['color'] = c.value;
                    _touch();
                  }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: currentColor == c.value ? brandSeed : Colors.black26,
                        width: currentColor == c.value ? 2.5 : 1,
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _fmtBtn(IconData icon, String tip, bool active, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(6),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: active ? brandSeed.withOpacity(0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 19, color: active ? brandSeed : null),
        ),
      ),
    );
  }

  // ---------- Barra de dibujo ----------
  Widget _penBar() {
    return Center(
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(24),
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              // Colores de lápiz
              for (final c in _penColors)
                GestureDetector(
                  onTap: () => setState(() {
                    _pen = c;
                    _eraser = false;
                  }),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: (!_eraser && _pen == c) ? brandSeed : Colors.black26,
                        width: (!_eraser && _pen == c) ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              // Grosores de trazo
              for (final w in const [(2.5, 'Fino'), (5.0, 'Medio'), (9.0, 'Grueso')])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: ChoiceChip(
                    label: Text(w.$2, style: const TextStyle(fontSize: 11.5)),
                    selected: !_eraser && !_highlighter && _penWidth == w.$1,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() {
                      _penWidth = w.$1;
                      _eraser = false;
                      _highlighter = false;
                    }),
                  ),
                ),
              // Modo resaltador
              IconButton(
                tooltip: 'Resaltador',
                icon: Icon(Icons.drive_file_rename_outline, color: _highlighter && !_eraser ? Colors.amber[800] : null),
                onPressed: () => setState(() {
                  _highlighter = !_highlighter;
                  _eraser = false;
                }),
              ),
              // Borrador de trazos
              IconButton(
                tooltip: 'Borrador (toca o arrastra sobre un trazo)',
                icon: Icon(Icons.cleaning_services_outlined, color: _eraser ? Colors.redAccent : null),
                onPressed: () => setState(() => _eraser = !_eraser),
              ),
              // Deshacer último trazo
              IconButton(
                tooltip: 'Deshacer trazo',
                icon: const Icon(Icons.undo),
                onPressed: () {
                  final e = _els.where((x) => x.id == _drawing).firstOrNull;
                  if (e == null) return;
                  final s = e.data['strokes'] as List;
                  if (s.isNotEmpty) {
                    setState(() {
                      s.removeLast();
                      _touch();
                    });
                  }
                },
              ),
              // Limpiar todo el dibujo
              IconButton(
                tooltip: 'Borrar todo el dibujo',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () {
                  final e = _els.where((x) => x.id == _drawing).firstOrNull;
                  if (e == null) return;
                  final s = e.data['strokes'] as List;
                  if (s.isNotEmpty) {
                    setState(() {
                      s.clear();
                      _touch();
                    });
                  }
                },
              ),
              FilledButton.tonalIcon(
                onPressed: () => setState(() => _drawing = null),
                icon: const Icon(Icons.done, size: 18),
                label: const Text('Listo'),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- marco de cada elemento ----------
  double get _scale => _tc.value.getMaxScaleOnAxis();

  Widget _frame(NoteElement e, bool darkNote) {
    final selected = _selected == e.id;
    final isDrawingThis = _drawing == e.id;
    final isCode = e.type == 'code';
    final panelColor = isCode
        ? const Color(0xFF282C34)
        : e.type == 'draw'
            ? Colors.white.withOpacity(darkNote ? 0.16 : 0.72)
            : Colors.white.withOpacity(darkNote ? 0.12 : 0.55);

    return Positioned(
      key: ValueKey(e.id),
      left: e.x,
      top: e.y,
      width: e.w,
      height: e.h,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTap: isDrawingThis
            ? null
            : () => setState(() {
                  _selected = e.id;
                  if (e.type == 'draw') {
                    _drawing = e.id;
                  }
                  _els.remove(e);
                  _els.add(e);
                }),
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isDrawingThis
                    ? brandMint
                    : selected
                        ? brandSeed
                        : Colors.black12,
                width: (selected || isDrawingThis) ? 2 : 1,
              ),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              _header(e, selected || isDrawingThis, isCode),
              Expanded(child: _content(e, selected)),
            ]),
          ),
          if (selected || isDrawingThis)
            Positioned(
              right: -10,
              bottom: -10,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => setState(() {
                  e.w = (e.w + d.delta.dx / _scale).clamp(140, 2400).toDouble();
                  e.h = (e.h + d.delta.dy / _scale).clamp(90, 2400).toDouble();
                  _touch();
                }),
                child: const CircleAvatar(
                  radius: 13,
                  backgroundColor: brandSeed,
                  child: Icon(Icons.open_in_full, size: 14, color: Colors.white),
                ),
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
          _mini(Icons.format_list_bulleted, 'Viñetas', () => _toggleListPrefix(e, 'bullet'), fg),
          _mini(Icons.check_box_outlined, 'Checklist', () => _toggleListPrefix(e, 'check'), fg),
          _mini(
            _editing == e.id ? Icons.visibility : Icons.edit,
            _editing == e.id ? 'Vista previa' : 'Editar texto',
            () => setState(() => _editing = _editing == e.id ? null : e.id),
            fg,
          ),
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
        actions.add(_mini(
          _editing == e.id ? Icons.visibility : Icons.edit,
          _editing == e.id ? 'Ver' : 'Editar',
          () => setState(() => _editing = _editing == e.id ? null : e.id),
          fg,
        ));
      } else if (e.type == 'link') {
        actions.add(_mini(Icons.edit, 'Editar enlace', () => _editLink(e), fg));
      } else if (e.type == 'draw') {
        final active = _drawing == e.id;
        actions.add(
          InkWell(
            onTap: () => setState(() => _drawing = active ? null : e.id),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(active ? Icons.pan_tool_alt_outlined : Icons.brush, size: 15, color: active ? brandSeed : fg),
                const SizedBox(width: 4),
                Text(
                  active ? 'Dibujando (toca para mover)' : 'Toca para dibujar',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? brandSeed : fg),
                ),
              ]),
            ),
          ),
        );
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
        height: 32,
        color: isCode ? Colors.black26 : Colors.black.withOpacity(0.06),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          Icon(Icons.drag_indicator, size: 18, color: fg),
          const SizedBox(width: 4),
          if (e.type == 'draw' && !selected)
            Text('Dibujo (toca para editar)', style: TextStyle(fontSize: 11, color: fg)),
          const Spacer(),
          ...actions,
        ]),
      ),
    );
  }

  Widget _mini(IconData i, String tip, VoidCallback onTap, Color c) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Tooltip(
          message: tip,
          child: Padding(padding: const EdgeInsets.all(5), child: Icon(i, size: 17, color: c)),
        ),
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
                child: Text(
                  (e.data['label'] ?? url).toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.blue, decoration: TextDecoration.underline, fontSize: 15),
                ),
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
    final bold = e.data['bold'] == true;
    final italic = e.data['italic'] == true;
    final underline = e.data['underline'] == true;
    final strike = e.data['strike'] == true;
    final quote = e.data['quote'] == true;
    final fontKey = (e.data['font'] ?? 'Sans').toString();
    final fontFamily = _fontFamilies[fontKey];
    final colorVal = (e.data['color'] as num?)?.toInt() ?? 0xDD000000;
    final alignStr = (e.data['align'] ?? 'left').toString();
    final textAlign = alignStr == 'center'
        ? TextAlign.center
        : alignStr == 'right'
            ? TextAlign.right
            : TextAlign.left;

    final decorations = <TextDecoration>[
      if (underline) TextDecoration.underline,
      if (strike) TextDecoration.lineThrough,
    ];

    final style = TextStyle(
      fontSize: size,
      fontFamily: fontFamily,
      color: Color(colorVal),
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine(decorations),
      height: 1.38,
    );

    final text = (e.data['text'] ?? '').toString();
    final hasLinks = _urlRe.hasMatch(text);

    Widget editorOrViewer;
    if (_editing != e.id && hasLinks) {
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
      editorOrViewer = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => setState(() => _editing = e.id),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(10),
          child: Text.rich(TextSpan(style: style, children: spans), textAlign: textAlign),
        ),
      );
    } else {
      editorOrViewer = TextField(
        controller: _ctrl(e, 'text'),
        style: style,
        textAlign: textAlign,
        maxLines: null,
        expands: true,
        keyboardType: TextInputType.multiline,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          hintText: 'Escribe aquí… (usa • para viñetas, 1. para listas)',
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.all(10),
        ),
        onTap: () => setState(() {
          _selected = e.id;
          _editing = e.id;
          _drawing = null;
        }),
        onChanged: (v) => _handleTextChanged(e, v),
      );
    }

    if (quote) {
      return Container(
        margin: const EdgeInsets.all(6),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: brandSeed, width: 4)),
        ),
        child: editorOrViewer,
      );
    }
    return editorOrViewer;
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
        _drawing = null;
      }),
      onChanged: (v) {
        e.data['text'] = v;
        _touch();
      },
    );
  }

  // ---------- Dibujo libre fluido (Listener directo sin conflicto con InteractiveViewer) ----------
  void _eraseAt(NoteElement e, Offset pos) {
    final list = e.data['strokes'] as List;
    const radiusSq = 280.0; // ~16.7px de radio de borrado
    list.removeWhere((raw) {
      final pts = (raw as Map)['p'] as List;
      for (var i = 0; i + 1 < pts.length; i += 2) {
        final dx = (pts[i] as num).toDouble() - pos.dx;
        final dy = (pts[i + 1] as num).toDouble() - pos.dy;
        if (dx * dx + dy * dy <= radiusSq) return true;
      }
      return false;
    });
  }

  void _startStrokeAt(NoteElement e, Offset localPos) {
    final x = localPos.dx.clamp(0.0, e.w);
    final y = localPos.dy.clamp(0.0, e.h);
    if (_eraser) {
      setState(() {
        _eraseAt(e, Offset(x, y));
        _touch();
      });
      return;
    }
    final strokeColor = _highlighter ? _pen.withOpacity(0.38).value : _pen.value;
    final strokeWidth = _highlighter ? 16.0 : (_pen == Colors.white ? 12.0 : _penWidth);
    setState(() {
      (e.data['strokes'] as List).add(Stroke(strokeColor, strokeWidth, [x, y]).toJson());
      _touch();
    });
  }

  void _appendStrokeAt(NoteElement e, Offset localPos) {
    // Auto-expansión suave si el usuario dibuja cerca del borde derecho o inferior en su celular
    if (localPos.dx > e.w - 18 && e.w < 2400) {
      e.w = math.min(2400, localPos.dx + 48);
    }
    if (localPos.dy > e.h - 50 && e.h < 2400) {
      e.h = math.min(2400, localPos.dy + 68);
    }
    final x = localPos.dx.clamp(0.0, e.w);
    final y = localPos.dy.clamp(0.0, e.h);
    if (_eraser) {
      setState(() {
        _eraseAt(e, Offset(x, y));
        _touch();
      });
      return;
    }
    final list = e.data['strokes'] as List;
    if (list.isEmpty) return;
    final pts = (list.last as Map)['p'] as List;
    if (pts.length >= 2) {
      final lastX = (pts[pts.length - 2] as num).toDouble();
      final lastY = (pts[pts.length - 1] as num).toDouble();
      if ((x - lastX).abs() < 0.8 && (y - lastY).abs() < 0.8) return;
    }
    setState(() {
      pts.addAll([x, y]);
      _touch();
    });
  }

  Widget _drawBody(NoteElement e) {
    final strokes = [
      for (final s in (e.data['strokes'] as List? ?? const [])) Stroke.fromJson(Map<String, dynamic>.from(s as Map))
    ];
    final active = _drawing == e.id;
    final painter = CustomPaint(painter: _StrokePainter(strokes), child: const SizedBox.expand());
    if (!active) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _selected = e.id;
          _drawing = e.id;
          _editing = null;
        }),
        child: painter,
      );
    }
    // Listener procesa eventos táctiles crudos (PointerDown / PointerMove) sin competir
    // con el ScaleGestureRecognizer de InteractiveViewer en Android.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (d) {
        if (_activePointer != null) return;
        _activePointer = d.pointer;
        _startStrokeAt(e, d.localPosition);
      },
      onPointerMove: (d) {
        if (_activePointer != d.pointer) return;
        _appendStrokeAt(e, d.localPosition);
      },
      onPointerUp: (d) {
        if (_activePointer == d.pointer) _activePointer = null;
      },
      onPointerCancel: (d) {
        if (_activePointer == d.pointer) _activePointer = null;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        onPanStart: (_) {},
        onPanUpdate: (_) {},
        child: MouseRegion(cursor: SystemMouseCursors.precise, child: painter),
      ),
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

      final pts = s.points;
      if (pts.length < 2) continue;
      if (pts.length == 2) {
        canvas.drawCircle(Offset(pts[0], pts[1]), s.width / 2, Paint()..color = Color(s.color));
        continue;
      }

      final path = Path()..moveTo(pts[0], pts[1]);
      if (pts.length == 4) {
        path.lineTo(pts[2], pts[3]);
      } else {
        for (var i = 2; i + 1 < pts.length; i += 2) {
          final prevX = pts[i - 2];
          final prevY = pts[i - 1];
          final currX = pts[i];
          final currY = pts[i + 1];
          final midX = (prevX + currX) / 2;
          final midY = (prevY + currY) / 2;
          path.quadraticBezierTo(prevX, prevY, midX, midY);
        }
        path.lineTo(pts[pts.length - 2], pts[pts.length - 1]);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
