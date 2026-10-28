import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'http_client_stub.dart' if (dart.library.io) 'http_client_io.dart';

class ActiveTimer {
  const ActiveTimer({required this.taskId, required this.title, required this.start});
  final int taskId;
  final String title;
  final DateTime start;

  int get elapsedSeconds => DateTime.now().difference(start).inSeconds.clamp(0, 86400 * 7);
  int get minutesToLog => (elapsedSeconds / 60).ceil().clamp(1, 1440);
}

class Api {
  Api(this.baseUrl, this.key);
  final String baseUrl;
  final String key;

  static const String appVersion = 'v0.3.0';
  static final http.Client _client = createResilientHttpClient();
  static final Map<String, dynamic> _memCache = {};
  static SharedPreferences? _prefs;

  /// Cronómetro global persistente (no se pierde al cambiar de pestaña ni al cerrar la app).
  static final ValueNotifier<ActiveTimer?> activeTimer = ValueNotifier<ActiveTimer?>(null);

  static const _diskKeys = <String>[
    'bundle',
    '/notes',
    '/calendars',
    '/weekly-blocks',
    '/stats',
  ];

  static Future<Api> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;

    // 1. Pre-cargar caché desde el disco local en memoria RAM para arranque instantáneo (< 50 ms)
    for (final k in p.getKeys()) {
      if (k.startsWith('cache_v3:')) {
        final memKey = k.substring('cache_v3:'.length);
        if (!_memCache.containsKey(memKey)) {
          final raw = p.getString(k);
          if (raw != null && raw.isNotEmpty) {
            try {
              _memCache[memKey] = jsonDecode(raw);
            } catch (_) {}
          }
        }
      }
    }

    // 2. Restaurar cronómetro activo si estaba corriendo antes de cerrar la app
    final tId = p.getInt('timer_task_id');
    final tTitle = p.getString('timer_task_title');
    final tStartMs = p.getInt('timer_start_ms');
    if (tId != null && tStartMs != null) {
      activeTimer.value = ActiveTimer(
        taskId: tId,
        title: tTitle ?? 'Tarea #$tId',
        start: DateTime.fromMillisecondsSinceEpoch(tStartMs),
      );
    }

    final savedUrl = p.getString('url')?.trim();
    final url = (savedUrl == null || savedUrl.isEmpty) ? 'https://agenda-personal-api.onrender.com' : savedUrl;
    return Api(url, p.getString('key') ?? '');
  }

  static Future<void> save(String url, String key) async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _prefs = p;
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final oldUrl = p.getString('url');
    await p.setString('url', cleanUrl);
    await p.setString('key', key.trim());
    if (oldUrl != null && oldUrl != cleanUrl) {
      _memCache.clear();
      for (final k in p.getKeys().where((k) => k.startsWith('cache_v3:')).toList()) {
        await p.remove(k);
      }
    }
  }

  static Future<void> startGlobalTimer(int taskId, String title) async {
    final now = DateTime.now();
    activeTimer.value = ActiveTimer(taskId: taskId, title: title, start: now);
    final p = _prefs ?? await SharedPreferences.getInstance();
    await p.setInt('timer_task_id', taskId);
    await p.setString('timer_task_title', title);
    await p.setInt('timer_start_ms', now.millisecondsSinceEpoch);
  }

  static Future<void> clearGlobalTimer() async {
    activeTimer.value = null;
    final p = _prefs ?? await SharedPreferences.getInstance();
    await p.remove('timer_task_id');
    await p.remove('timer_task_title');
    await p.remove('timer_start_ms');
  }

  Map<String, String> get _h => {'Content-Type': 'application/json', if (key.isNotEmpty) 'X-API-Key': key};

  dynamic peekCache(String cacheKey) => _memCache[cacheKey];

  void setCache(String cacheKey, dynamic val, {bool persist = true}) {
    _memCache[cacheKey] = val;
    if (persist && (_diskKeys.contains(cacheKey) || cacheKey.startsWith('/notes/'))) {
      _persistAsync(cacheKey, val);
    }
  }

  static void _persistAsync(String cacheKey, dynamic val) {
    final p = _prefs;
    if (p == null) return;
    Future.microtask(() async {
      try {
        await p.setString('cache_v3:$cacheKey', jsonEncode(val));
      } catch (_) {}
    });
  }

  void invalidateCache() {
    _memCache.clear();
  }

  /// Actualiza optimistamente la lista de tareas dentro del bundle en caché (RAM + Disco).
  void mutateCachedTasks(void Function(List<Map<String, dynamic>> tasks) fn) {
    final b = _memCache['bundle'];
    if (b is! Map) return;
    final bundle = Map<String, dynamic>.from(b);
    final raw = (bundle['tasks'] as List?) ?? const [];
    final list = [for (final t in raw) Map<String, dynamic>.from(t as Map)];
    fn(list);
    bundle['tasks'] = list;
    setCache('bundle', bundle);
  }

  Future<dynamic> _check(http.Response r) async {
    if (r.statusCode >= 400) throw Exception('Error ${r.statusCode}: ${utf8.decode(r.bodyBytes)}');
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<dynamic> get(String path) async {
    final res = await _check(
      await _client.get(Uri.parse('$baseUrl$path'), headers: _h).timeout(const Duration(seconds: 45)),
    );
    setCache(path, res);
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
    if (path.startsWith('/notes/') && res is Map) {
      setCache(path, res);
    }
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
    _memCache.remove(path);
    _prefs?.remove('cache_v3:$path');
    return res;
  }

  /// Carga unificada rápida (/bundle) con respaldo automático a los endpoints individuales
  /// y persistencia inmediata en disco para apertura instantánea en frío.
  Future<Map<String, dynamic>> getBundle({int days = 90, int back = 30, bool refresh = false}) async {
    try {
      final data = await get('/bundle?days=$days&back=$back&refresh=$refresh') as Map;
      final out = Map<String, dynamic>.from(data);
      setCache('bundle', out);
      if (out['weekly_blocks'] is List) {
        setCache('/weekly-blocks', out['weekly_blocks']);
      }
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
      setCache('bundle', out);
      return out;
    }
  }
}
