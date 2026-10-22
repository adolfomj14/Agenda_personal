import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  Api(this.baseUrl, this.key);
  final String baseUrl;
  final String key;

  static final http.Client _client = http.Client();
  static final Map<String, dynamic> _memCache = {};

  static Future<Api> load() async {
    final p = await SharedPreferences.getInstance();
    return Api(p.getString('url') ?? 'http://127.0.0.1:8000', p.getString('key') ?? '');
  }

  static Future<void> save(String url, String key) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    await p.setString('key', key.trim());
    _memCache.clear();
  }

  Map<String, String> get _h => {'Content-Type': 'application/json', if (key.isNotEmpty) 'X-API-Key': key};

  dynamic peekCache(String key) => _memCache[key];

  void setCache(String key, dynamic val) {
    _memCache[key] = val;
  }

  void invalidateCache() {
    _memCache.clear();
  }

  Future<dynamic> _check(http.Response r) async {
    if (r.statusCode >= 400) throw Exception('Error ${r.statusCode}: ${utf8.decode(r.bodyBytes)}');
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<dynamic> get(String path) async {
    final res = await _check(
      await _client.get(Uri.parse('$baseUrl$path'), headers: _h).timeout(const Duration(seconds: 45)),
    );
    _memCache[path] = res;
    return res;
  }

  Future<dynamic> post(String path, [Object? body]) async {
    final res = await _check(
      await _client.post(Uri.parse('$baseUrl$path'), headers: _h, body: jsonEncode(body ?? {})),
    );
    return res;
  }

  Future<dynamic> put(String path, Object body) async {
    final res = await _check(
      await _client.put(Uri.parse('$baseUrl$path'), headers: _h, body: jsonEncode(body)),
    );
    return res;
  }

  Future<dynamic> patch(String path, Object body) async {
    final res = await _check(
      await _client.patch(Uri.parse('$baseUrl$path'), headers: _h, body: jsonEncode(body)),
    );
    return res;
  }

  Future<dynamic> delete(String path) async {
    final res = await _check(
      await _client.delete(Uri.parse('$baseUrl$path'), headers: _h),
    );
    return res;
  }

  /// Carga unificada rápida (/bundle) con respaldo automático a los endpoints individuales
  /// por si el servidor en Render aún está desplegando la versión nueva.
  Future<Map<String, dynamic>> getBundle({int days = 90, int back = 30, bool refresh = false}) async {
    try {
      final data = await get('/bundle?days=$days&back=$back&refresh=$refresh') as Map;
      final out = Map<String, dynamic>.from(data);
      _memCache['bundle'] = out;
      return out;
    } catch (_) {
      final results = await Future.wait([
        get('/events?days=$days&back=$back'),
        get('/plan?days=30'),
        get('/tasks?include_done=true'),
      ]);
      final ev = results[0] as Map;
      final pl = results[1] as Map;
      final tk = results[2] as List;
      List<dynamic> wbs = [];
      try {
        wbs = await get('/weekly-blocks') as List;
      } catch (_) {}
      final out = <String, dynamic>{
        'events': ev['events'],
        'conflicts': ev['conflicts'],
        'plan': pl,
        'tasks': tk,
        'weekly_blocks': wbs,
      };
      _memCache['bundle'] = out;
      return out;
    }
  }
}
