import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  Api(this.baseUrl, this.key);
  final String baseUrl;
  final String key;

  static Future<Api> load() async {
    final p = await SharedPreferences.getInstance();
    return Api(p.getString('url') ?? 'http://127.0.0.1:8000', p.getString('key') ?? '');
  }

  static Future<void> save(String url, String key) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('url', url.trim().replaceAll(RegExp(r'/+$'), ''));
    await p.setString('key', key.trim());
  }

  Map<String, String> get _h => {'Content-Type': 'application/json', if (key.isNotEmpty) 'X-API-Key': key};

  Future<dynamic> _check(http.Response r) async {
    if (r.statusCode >= 400) throw Exception('Error ${r.statusCode}: ${utf8.decode(r.bodyBytes)}');
    return r.bodyBytes.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<dynamic> get(String path) async =>
      _check(await http.get(Uri.parse('$baseUrl$path'), headers: _h).timeout(const Duration(seconds: 60)));
  Future<dynamic> post(String path, [Object? body]) async => _check(
      await http.post(Uri.parse('$baseUrl$path'), headers: _h, body: jsonEncode(body ?? {})));
  Future<dynamic> put(String path, Object body) async =>
      _check(await http.put(Uri.parse('$baseUrl$path'), headers: _h, body: jsonEncode(body)));
  Future<dynamic> patch(String path, Object body) async =>
      _check(await http.patch(Uri.parse('$baseUrl$path'), headers: _h, body: jsonEncode(body)));
  Future<dynamic> delete(String path) async =>
      _check(await http.delete(Uri.parse('$baseUrl$path'), headers: _h));
}
