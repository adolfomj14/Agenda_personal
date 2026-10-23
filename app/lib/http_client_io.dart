import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

final Map<String, InternetAddress> _dnsCache = {};

/// Resuelve un dominio por DNS sobre HTTPS (1.1.1.1 / 8.8.8.8) conectando por IP directa
/// sin usar el resolvedor DNS del sistema operativo (evita SocketException errno = 7 en redes móviles).
Future<InternetAddress?> _resolveViaDoH(String host) async {
  for (final endpoint in const [
    ('1.1.1.1', 'cloudflare-dns.com', '/dns-query'),
    ('8.8.8.8', 'dns.google', '/resolve'),
  ]) {
    final dohClient = HttpClient();
    dohClient.connectionTimeout = const Duration(seconds: 4);
    dohClient.connectionFactory = (Uri uri, String? pHost, int? pPort) async {
      final ip = InternetAddress(endpoint.$1);
      final raw = Socket.connect(ip, 443, timeout: const Duration(seconds: 4));
      final sec = raw.then((s) => SecureSocket.secure(s, host: endpoint.$2));
      return ConnectionTask.fromSocket(sec, () {});
    };
    try {
      final req = await dohClient
          .getUrl(Uri.parse('https://${endpoint.$2}${endpoint.$3}?name=${Uri.encodeComponent(host)}&type=A'))
          .timeout(const Duration(seconds: 4));
      req.headers.set('accept', 'application/dns-json');
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is Map && data['Answer'] is List) {
          for (final ans in data['Answer'] as List) {
            if (ans is Map && ans['type'] == 1 && ans['data'] is String) {
              final parsed = InternetAddress.tryParse(ans['data'] as String);
              if (parsed != null) return parsed;
            }
          }
        }
      }
    } catch (_) {
      // Intentar siguiente servidor DoH
    } finally {
      dohClient.close(force: true);
    }
  }
  return null;
}

Future<InternetAddress> _resolveHostResilient(String host) async {
  final direct = InternetAddress.tryParse(host);
  if (direct != null) return direct;

  try {
    final addrs = await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
    if (addrs.isNotEmpty) {
      final ipv4 = addrs.where((a) => a.type == InternetAddressType.IPv4).firstOrNull ?? addrs.first;
      _dnsCache[host] = ipv4;
      return ipv4;
    }
  } catch (_) {
    // El DNS del sistema falló (ej. errno = 7 en datos móviles Android).
  }

  final cached = _dnsCache[host];
  if (cached != null) return cached;

  final doh = await _resolveViaDoH(host);
  if (doh != null) {
    _dnsCache[host] = doh;
    return doh;
  }

  // Respaldo final para servidores hospedados en Render (Cloudflare Anycast IP)
  if (host.endsWith('.onrender.com')) {
    final fallback = InternetAddress('216.24.57.16');
    _dnsCache[host] = fallback;
    return fallback;
  }

  throw SocketException("No se pudo resolver '$host' ni por DNS local ni por DoH (1.1.1.1)");
}

http.Client createResilientHttpClient() {
  final io = HttpClient();
  io.connectionTimeout = const Duration(seconds: 15);
  io.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final isSecure = uri.scheme == 'https';

    Future<Socket> connectFuture() async {
      final targetIp = await _resolveHostResilient(host);
      final raw = await Socket.connect(targetIp, port, timeout: const Duration(seconds: 15));
      if (isSecure) {
        return SecureSocket.secure(raw, host: host);
      }
      return raw;
    }

    return ConnectionTask.fromSocket(connectFuture(), () {});
  };
  return IOClient(io);
}
