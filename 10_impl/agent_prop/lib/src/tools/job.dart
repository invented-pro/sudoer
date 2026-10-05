import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../models.dart';
import '../platform.dart';
import 'tool.dart';

/// Cap on a job's un-polled output retained between polls (C3/C8):
/// compiled-in, not configuration. The earliest output is dropped past it.
const int kJobOutputCap = 64 * 1024;

/// A running background command (C3): the process, its un-polled output, and
/// its exit state.
final class Job {
  Job({
    required this.id,
    required this.command,
    required this.process,
    required this.grouped,
    required this.shell,
  }) {
    startedAt = DateTime.now();
    process.stdout.transform(utf8.decoder).listen(_append,
        onError: (_) {}, onDone: () => _outDone.complete());
    process.stderr.transform(utf8.decoder).listen(_append,
        onError: (_) {}, onDone: () => _errDone.complete());
    process.exitCode.then((code) {
      exitCode = code;
      _exited.complete();
    }, onError: (Object _) {
      exitCode = -1;
      _exited.complete();
    });
  }

  final String id;
  final String command;
  final Process process;
  final bool grouped;
  final HostShell shell;

  late final DateTime startedAt;
  int? exitCode;
  bool stopRequested = false;

  final _exited = Completer<void>();
  final _outDone = Completer<void>();
  final _errDone = Completer<void>();
  final List<String> _pending = [];
  int _pendingLength = 0;

  void _append(String chunk) {
    if (chunk.isEmpty) return;
    _pending.add(chunk);
    _pendingLength += chunk.length;
    if (_pendingLength > kJobOutputCap) {
      final all = _pending.join();
      final kept = '[earlier output dropped]\n'
          '${all.substring(all.length - kJobOutputCap)}';
      _pending
        ..clear()
        ..add(kept);
      _pendingLength = kept.length;
    }
  }

  /// Output produced since the last poll (bounded by the retained window).
  String drainOutput() {
    if (_pending.isEmpty) return '';
    final text = _pending.join();
    _pending.clear();
    _pendingLength = 0;
    return text;
  }

  Future<void> get exited => _exited.future;

  Future<void> get outputClosed => Future.wait([_outDone.future, _errDone.future]);

  Future<void> stop() async {
    stopRequested = true;
    await shell.killTree(process, grouped);
  }

  /// One-line status: `running`, or the exit code once it has ended.
  String statusLine() {
    final code = exitCode;
    final seconds =
        (DateTime.now().difference(startedAt).inMilliseconds / 1000)
            .toStringAsFixed(1);
    if (code == null) return '$id: running ${seconds}s — $command';
    return '$id: exited $code — $command';
  }
}

/// C3/C8: the session's background jobs. One registry is shared across agent
/// rebuilds (workspace changes) so no job is orphaned; every job is reaped
/// when the run is cancelled or the session closes.
final class JobRegistry {
  JobRegistry({HostShell? shell}) : shell = shell ?? HostShell.host;

  final HostShell shell;
  final Map<String, Job> _jobs = {};
  int _counter = 0;

  List<String> get ids => _jobs.keys.toList()..sort();

  Job? lookup(String id) => _jobs[id];

  Future<Job> start(String command, String workingDirectory) async {
    final id = 'job${++_counter}';
    final (process, grouped) = await shell.start(command, workingDirectory);
    final job = Job(
      id: id,
      command: command,
      process: process,
      grouped: grouped,
      shell: shell,
    );
    _jobs[id] = job;
    return job;
  }

  /// Kill every live job (a cancel or the session closing); never throws.
  Future<void> reapAll() async {
    for (final job in _jobs.values.toList()) {
      try {
        if (job.exitCode == null) await job.stop();
      } on Object {
        // Reaping is best-effort; a dead process is already reaped.
      }
    }
  }
}

/// job (C3): start, poll, or stop a background command (dev servers,
/// watchers) so it runs while the loop keeps working.
final class JobTool extends Tool implements Cancellable {
  JobTool(super.guard, {JobRegistry? jobs}) : _registry = jobs;

  /// Shared registry; when null a private one is created lazily (and owned
  /// by the assembled agent, which reaps it on dispose).
  JobRegistry? _registry;

  JobRegistry get registry => _registry ??= JobRegistry();

  @override
  String get name => 'job';

  @override
  String get description =>
      'Start, poll, or stop a background command (a dev server or watcher): '
      'start {command}, poll {id} for new output and status, stop {id}.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['action'],
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['start', 'poll', 'stop'],
          },
          'command': {'type': 'string'},
          'id': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) {
    final action = args['action'];
    if (action is! String ||
        !const ['start', 'poll', 'stop'].contains(action)) {
      return 'argument action must be one of: start, poll, stop';
    }
    if (action == 'start') return requireString(args, 'command');
    return requireString(args, 'id');
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) =>
      _run(args, null);

  @override
  Future<ToolOutcome> executeCancellable(
          Map<String, dynamic> args, CancelSignal cancel) =>
      _run(args, cancel);

  Future<ToolOutcome> _run(Map<String, dynamic> args, CancelSignal? cancel) {
    final action = args['action'] as String;
    return switch (action) {
      'start' => _start(args['command'] as String, cancel),
      'poll' => _poll(args['id'] as String),
      'stop' => _stop(args['id'] as String),
      _ => Future.value(
          ToolOutcome.error('argument action must be one of: start, poll, stop')),
    };
  }

  Future<ToolOutcome> _start(String command, CancelSignal? cancel) async {
    if (cancel?.isCancelled ?? false) {
      return const ToolOutcome.error('command cancelled');
    }
    final dir = p.normalize(p.absolute(workspaceRoot));
    try {
      final job = await registry.start(command, dir);
      return ToolOutcome.ok('${job.statusLine()} (poll with '
          '{"action":"poll","id":"${job.id}"})');
    } on Object catch (e) {
      return ToolOutcome.error('cannot start job: $e');
    }
  }

  Future<ToolOutcome> _poll(String id) async {
    final job = registry.lookup(id);
    if (job == null) return ToolOutcome.error('unknown job: $id');
    final output = job.drainOutput();
    final status = job.statusLine();
    return ToolOutcome.ok(output.isEmpty ? status : '$status\n$output');
  }

  Future<ToolOutcome> _stop(String id) async {
    final job = registry.lookup(id);
    if (job == null) return ToolOutcome.error('unknown job: $id');
    try {
      if (job.exitCode == null) await job.stop();
      // Give the tree a moment to die and flush its pipes, bounded.
      await job.exited.timeout(const Duration(seconds: 5),
          onTimeout: () {});
      final output = job.drainOutput();
      final status = job.statusLine();
      return ToolOutcome.ok(output.isEmpty ? status : '$status\n$output');
    } on Object catch (e) {
      return ToolOutcome.error('cannot stop $id: $e');
    }
  }
}
