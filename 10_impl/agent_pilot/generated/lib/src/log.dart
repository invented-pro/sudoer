import 'dart:convert';
import 'dart:io';

import 'clock.dart';
import 'safety.dart';

/// C8: the append-only structured JSONL event log. One line per event to
/// [path] (`log_file`); times come from the injected clock; secret values
/// are scrubbed by the safety layer's [Secrets.scrub] before any line is
/// written (C10). Appending is line-atomic for a single writer; every kind
/// is frozen in `00_bp/agent_pilot/log.schema.json`.
final class StructuredLog {
  StructuredLog(this._path, this._clock, {this.enabled = true});

  final String _path;
  final Clock _clock;
  final bool enabled;

  /// Ordered kinds written so far (read back on load), so the gate can
  /// assert a live object's record without re-reading the file.
  final List<LogRecord> records = [];

  /// Emit one event of [kind]; [data] is the kind's frozen data shape.
  void emit(String kind, Map<String, dynamic> data, {String? session}) async {
    if (!enabled) return;
    final record = LogRecord(_clock.now().toIso8601String(), kind, data,
        session: session);
    records.add(record);
    final file = File(_path);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    if (!file.existsSync()) file.createSync(recursive: true);
    // Append one JSONL line synchronously (an event log write is one line):
    // the caller never sees a torn or delayed line, and an expectation
    // reader always sees what was emitted (C8: append-only, line-atomic).
    file.writeAsStringSync(
        '${jsonEncode(record.toJson())}\n',
        mode: FileMode.append);
  }

  void emitRunStart(String goal, {required String session, bool system = false}) => emit('run_start', {'goal': goal, 'origin': system ? 'system' : 'user'},
          session: session);

  void emitRunEnd(String status, int steps, {String? answer, String? session}) => emit('run_end', {
        'status': status,
        'steps': steps,
        'answer': ?answer,
      }, session: session);

  void emitToolCall(String tool, String outcome, {String? detail, String? session}) => emit('tool_call', {
        'tool': tool,
        'outcome': outcome,
        'detail': ?detail,
      }, session: session);

  void emitProviderCall(int provider, String outcome, {bool? failover, String? session}) => emit('provider_call', {
        'provider': provider,
        'outcome': outcome,
        'failover': ?failover,
      }, session: session);

  void emitTask(String task, String action, {DateTime? due, String? repeat, String? session}) => emit('task_${action == 'scheduled' ? 'scheduled' : action}', {
        'task': task,
        'action': action,
        if (due != null) 'due': due.toIso8601String(),
        'repeat': ?repeat,
      }, session: session);

  /// `channel_in` / `channel_out` carry the `in`/`out` action; the refused
  /// path is a `channel_in` line with `action: denied` (log.schema.json).
  void emitChannel(String channel, String action,
          {String? from, String? to, String? task, String? session}) =>
      emit(
          action == 'out' ? 'channel_out' : 'channel_in',
          {
            'channel': channel,
            'action': action,
            'from': ?from,
            'to': ?to,
            'task': ?task,
          },
          session: session);

  void emitConfigChanged(List<String> keys, {String? session}) => emit('config_changed', {'action': 'changed', 'keys': keys},
          session: session);

  void emitService(String action, {DateTime? nextDue}) => emit('service_$action', {
        'action': action,
        if (nextDue != null) 'next_due': nextDue.toIso8601String(),
      });

  /// Read back every event in the file, in order (the gate asserts this).
  static List<LogRecord> load(String path) {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final records = <LogRecord>[];
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final json = jsonDecode(line) as Map<String, dynamic>;
      records.add(LogRecord(
        json['time'] as String,
        json['kind'] as String,
        (json['data'] as Map? ?? const {}).cast<String, dynamic>(),
        session: json['session'] as String?,
      ));
    }
    return records;
  }
}

/// One structured event, mirroring `log.schema.json` `logEvent`.
final class LogRecord {
  LogRecord(this.time, this.kind, this.data, {this.session});
  final String time;
  final String kind;
  final Map<String, dynamic> data;
  final String? session;

  Map<String, dynamic> toJson() => {
        'time': time,
        'kind': kind,
        'session': ?session,
        'data': data,
      };
}
