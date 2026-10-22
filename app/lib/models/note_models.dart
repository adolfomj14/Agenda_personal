import 'dart:convert';

/// Un elemento dentro del lienzo de una nota: texto, código, imagen, enlace o dibujo.
class NoteElement {
  NoteElement({
    required this.id,
    required this.type,
    this.x = 40,
    this.y = 40,
    this.w = 240,
    this.h = 140,
    Map<String, dynamic>? data,
  }) : data = data ?? <String, dynamic>{};

  final String id;
  final String type; // text | code | image | link | draw
  double x, y, w, h;
  Map<String, dynamic> data;

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  factory NoteElement.fromJson(Map<String, dynamic> j) => NoteElement(
        id: (j['id'] ?? newId()).toString(),
        type: (j['type'] ?? 'text').toString(),
        x: (j['x'] as num?)?.toDouble() ?? 40,
        y: (j['y'] as num?)?.toDouble() ?? 40,
        w: (j['w'] as num?)?.toDouble() ?? 240,
        h: (j['h'] as num?)?.toDouble() ?? 140,
        data: Map<String, dynamic>.from((j['data'] as Map?) ?? const {}),
      );

  Map<String, dynamic> toJson() => {'id': id, 'type': type, 'x': x, 'y': y, 'w': w, 'h': h, 'data': data};

  static List<NoteElement> decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      final raw = jsonDecode(s) as List;
      return [for (final e in raw) NoteElement.fromJson(Map<String, dynamic>.from(e as Map))];
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<NoteElement> l) => jsonEncode([for (final e in l) e.toJson()]);

  /// Texto plano para búsqueda y vista previa.
  String get plainText {
    switch (type) {
      case 'text':
      case 'code':
        return (data['text'] ?? '').toString();
      case 'link':
        return '${data['label'] ?? ''} ${data['url'] ?? ''}'.trim();
      default:
        return '';
    }
  }
}

/// Un trazo de un dibujo: color ARGB, grosor y puntos [x0,y0,x1,y1,...] relativos al elemento.
class Stroke {
  Stroke(this.color, this.width, this.points);
  final int color;
  final double width;
  final List<double> points;

  Map<String, dynamic> toJson() => {'c': color, 'w': width, 'p': points};
  factory Stroke.fromJson(Map<String, dynamic> j) => Stroke(
        (j['c'] as num).toInt(),
        (j['w'] as num).toDouble(),
        [for (final v in (j['p'] as List)) (v as num).toDouble()],
      );
}

const notePalette = <String>[
  '#FFF59D', '#FFCCBC', '#F8BBD0', '#E1BEE7', '#C5CAE9', '#B2EBF2', '#C8E6C9', '#FFFFFF', '#37474F',
];
