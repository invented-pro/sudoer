import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The gate's loopback stub: a canned HTTP responder bound to 127.0.0.1 on
/// an ephemeral port. `{{stub:name}}` in a goal or script argument resolves
/// to the bound origin. No non-loopback network is permitted by the suite;
/// a task that reaches elsewhere fails on its own (host unreachable).
final class LoopbackStub {
  LoopbackStub._(this.name, this.server, this.status, this.headers, this.body);

  final String name;
  final HttpServer server;
  final int status;
  final Map<String, String> headers;
  final String body;

  String get origin => 'http://127.0.0.1:${server.port}';

  /// Bind [count] named stubs; the returned map drives `{{stub:name}}`
  /// resolution. Servers are closed by [closeAll].
  static Future<(Map<String, LoopbackStub>, Future<void> Function())> bind(
      List<({String name, int status, Map<String, String> headers, String body})>
          stubs) async {
    final bound = <String, LoopbackStub>{};
    for (final stub in stubs) {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final entry = LoopbackStub._(
          stub.name, server, stub.status, stub.headers, stub.body);
      server.listen((request) async {
        // Consume the request body so the socket stays clean.
        await utf8.decoder.bind(request).join();
        request.response.statusCode = entry.status;
        entry.headers.forEach(request.response.headers.set);
        request.response.headers.set('content-type',
            entry.headers.containsKey('content-type')
                ? entry.headers['content-type']!
                : 'text/plain');
        request.response.write(entry.body);
        await request.response.close();
      });
      bound[stub.name] = entry;
    }
    return (
      bound,
      () async {
        for (final stub in bound.values) {
          await stub.server.close(force: true);
        }
      }
    );
  }
}

/// Resolve `{{stub:name}}` tokens in [text] against the bound stubs.
String resolveStubs(String text, Map<String, LoopbackStub> stubs) => text
    .replaceAllMapped(RegExp(r'\{\{stub:([a-z][a-z0-9-]*)\}\}'), (match) {
  final stub = stubs[match.group(1)];
  if (stub == null) return match.group(0)!;
  return stub.origin;
});
