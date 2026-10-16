import 'dart:convert';
import 'dart:io';

import 'clock.dart';

/// C10: the secrets store. A JSON map of {name: value} at `secrets_file`
/// (0600 on POSIX). Values are injected at connectors and scrubbed from
/// every observation, transcript, and log line; only names are ever shown
/// to the model or returned over the API.
final class Secrets {
  Secrets(this._path, this._clock, {this.onDecision});

  final String _path;

  /// The clock stamps `secret_used` decisions (kept for symmetry with the
  /// other stores' clocks).
  // ignore: unused_field
  final Clock _clock;

  /// The decision sink (`secret_used`); null in unit tests that assert the
  /// store directly.
  final void Function(String event, String tool, String? detail)? onDecision;

  Map<String, String>? _cache;

  Map<String, String> get values {
    final cached = _cache;
    if (cached != null) return cached;
    final file = File(_path);
    if (!file.existsSync()) {
      _cache = const {};
      return _cache!;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      _cache = const {};
      return _cache!;
    }
    _cache = {
      for (final entry in decoded.entries)
        if (entry.value is String && (entry.value as String).isNotEmpty)
          entry.key as String: entry.value as String,
    };
    return _cache!;
  }

  List<String> get names => values.keys.toList()..sort();

  /// The value of [name], or null when the secret is not configured.
  String? resolve(String name) {
    final value = values[name];
    if (value != null) {
      onDecision?.call('secret_used', 'http', name);
    }
    return value;
  }

  /// Replace every configured secret value in [text] with `«secret:name»`
  /// (C10). Longest value first so overlapping values scrub fully.
  String scrub(String text) {
    var out = text;
    final entries = values.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final entry in entries) {
      if (entry.value.isEmpty) continue;
      out = out.replaceAll(entry.value, '«secret:${entry.key}»');
    }
    return out;
  }

  /// Scrub a tool observation before it enters the transcript (C10).
  String scrubObservation(String text) => scrub(text);
}

/// C10: the append-only JSONL decision log (`policy.log`). Every policy
/// decision — network denial, confirm asked/granted/denied, secret used,
/// API auth failure, channel sender denied, config changed — is one line,
/// frozen in `policy.schema.json`.
final class DecisionLog {
  DecisionLog(this.path, this.clock);

  final String path;
  final Clock clock;

  /// In-memory mirror of the file's records, so a live object can be
  /// asserted without re-reading.
  final List<Map<String, dynamic>> records = [];

  void add(String event, String tool, {String? detail, String? session}) {
    final record = <String, dynamic>{
      'time': clock.now().toIso8601String(),
      'event': event,
      'tool': tool,
      'detail': ?detail,
      'session': ?session,
    };
    records.add(record);
    final file = File(path);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    if (!file.existsSync()) file.createSync(recursive: true);
    file.writeAsStringSync('${jsonEncode(record)}\n',
        mode: FileMode.append);
  }

  /// Read back every decision in the file, in order.
  static List<Map<String, dynamic>> load(String path) {
    final file = File(path);
    if (!file.existsSync()) return const [];
    return [
      for (final line in file.readAsLinesSync())
        if (line.trim().isNotEmpty)
          (jsonDecode(line) as Map).cast<String, dynamic>(),
    ];
  }
}
