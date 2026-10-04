import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../errors.dart';
import '../models.dart';
import '../platform.dart';
import '../reliability.dart';

/// The workspace confinement policy (C3, C8). File tools resolve paths through
/// it; a path that escapes [root] is a guard denial unless the user has
/// authorized outside-workspace access for the session ([allowOutside]).
final class WorkspaceGuard {
  WorkspaceGuard(this.root);

  final String root;

  /// Set once the user approves an out-of-workspace access; the grant lasts
  /// for the session (C6).
  bool allowOutside = false;

  File resolve(String path) {
    final normalizedRoot = p.normalize(p.absolute(root));
    final resolved = p.normalize(p.join(normalizedRoot, path));
    if (!allowOutside &&
        resolved != normalizedRoot &&
        !p.isWithin(normalizedRoot, resolved)) {
      throw GuardDeniedException('path escapes workspace: $path');
    }
    return File(resolved);
  }
}

/// The network egress policy (C3). Enabled and open by default; [denyHosts] is
/// an empty blacklist reserved for later policy. A denial is a hard block:
/// unlike the workspace guard there is no interactive override.
final class NetworkGuard {
  NetworkGuard({this.enabled = true, this.denyHosts = const []});

  final bool enabled;
  final List<String> denyHosts;

  bool allowsHost(String host) => enabled && !_denied(host);

  bool _denied(String host) {
    final h = host.toLowerCase();
    return denyHosts.any((entry) {
      final e = entry.toLowerCase();
      if (e.startsWith('.')) return h == e.substring(1) || h.endsWith(e);
      return h == e;
    });
  }

  /// Throws [GuardDeniedException] (area `network`) unless egress to [uri] is
  /// permitted by configuration.
  void check(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const GuardDeniedException('only http/https URLs can be fetched',
          area: GuardArea.network);
    }
    if (!enabled) {
      throw const GuardDeniedException(
          'web access is disabled; set web.enabled in the config to allow it',
          area: GuardArea.network);
    }
    if (_denied(uri.host)) {
      throw GuardDeniedException(
          'web egress to ${uri.host} is blocked by web.deny_hosts',
          area: GuardArea.network);
    }
  }
}

/// A built-in tool (C3): a named function with a schema and an effect.
abstract class Tool {
  Tool(this.guard);

  final WorkspaceGuard guard;

  String get workspaceRoot => guard.root;

  String get name;
  String get description;
  Map<String, dynamic> get parameters;

  /// Per-tool-class timeout (C8); `run_command` overrides with the build
  /// timeout so compilers and tests can finish.
  Duration get timeout => kModelTimeout;

  /// Return an error string if [arguments] are invalid, else null.
  String? validate(Map<String, dynamic> arguments);

  Future<ToolOutcome> execute(Map<String, dynamic> arguments);

  ToolDefinition get definition => ToolDefinition(
        name: name,
        description: description,
        parameters: parameters,
      );
}

/// A tool whose execution can be aborted mid-flight (C8). The registry hands
/// it the run's cancel signal; tools that do not implement it are short enough
/// to let finish before the loop notices the cancel.
abstract interface class Cancellable {
  Future<ToolOutcome> executeCancellable(
      Map<String, dynamic> args, CancelSignal cancel);
}

String? requireString(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return 'missing required argument: $key';
  if (value is! String) return 'argument $key must be a string';
  return null;
}

/// Dispatches actions (C1) to the fixed built-in catalog (C3).
final class ToolRegistry {
  factory ToolRegistry({
    required String workspaceRoot,
    WorkspaceGuard? guard,
    List<Tool>? tools,
    List<String>? callLog,
  }) {
    final resolvedGuard = guard ?? WorkspaceGuard(workspaceRoot);
    return ToolRegistry._(
      guard: resolvedGuard,
      tools: {
        for (final tool in tools ?? builtinTools(resolvedGuard))
          tool.name: tool,
      },
      callLog: callLog ?? [],
    );
  }

  ToolRegistry._({
    required this.guard,
    required this.tools,
    required this.callLog,
  });

  final WorkspaceGuard guard;
  String get workspaceRoot => guard.root;
  final Map<String, Tool> tools;

  /// Ordered names of dispatched tool calls, for the gate.
  final List<String> callLog;

  List<ToolDefinition> get definitions =>
      tools.values.map((tool) => tool.definition).toList();

  Duration timeoutFor(String name) => tools[name]?.timeout ?? kModelTimeout;

  Future<ToolOutcome> dispatch(ToolCall call, {CancelSignal? cancel}) async {
    callLog.add(call.name);
    final tool = tools[call.name];
    if (tool == null) {
      if (call.name.isEmpty) {
        return ToolOutcome.error('tool call is missing a name; '
            'available tools: ${tools.keys.join(', ')}');
      }
      return ToolOutcome.error('unknown tool: ${call.name}');
    }
    final invalid = tool.validate(call.arguments);
    if (invalid != null) return ToolOutcome.error(invalid);
    try {
      if (cancel != null && tool is Cancellable) {
        return await (tool as Cancellable)
            .executeCancellable(call.arguments, cancel);
      }
      return await tool.execute(call.arguments);
    } on GuardDeniedException catch (e) {
      return ToolOutcome.guardDenied(e.message, guard: e.area);
    } on FileSystemException catch (e) {
      return ToolOutcome.error(e.message);
    }
  }
}

/// The fixed Prop catalog: read, write, edit, run_command, search.
List<Tool> builtinTools(WorkspaceGuard guard) => [
      ReadTool(guard),
      WriteTool(guard),
      EditTool(guard),
      RunCommandTool(guard),
      SearchTool(guard),
    ];

final class ReadTool extends Tool {
  ReadTool(super.guard);

  @override
  String get name => 'read';

  @override
  String get description => 'Read a file from the workspace.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) => requireString(args, 'path');

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final file = guard.resolve(args['path'] as String);
    if (!file.existsSync()) {
      return ToolOutcome.error('no such file: ${args['path']}');
    }
    return ToolOutcome.ok(file.readAsStringSync());
  }
}

final class WriteTool extends Tool {
  WriteTool(super.guard);

  @override
  String get name => 'write';

  @override
  String get description => 'Create or overwrite a file in the workspace.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path', 'content'],
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) =>
      requireString(args, 'path') ?? requireString(args, 'content');

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final file = guard.resolve(args['path'] as String);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(args['content'] as String);
    return ToolOutcome.ok('wrote ${args['path']}');
  }
}

final class EditTool extends Tool {
  EditTool(super.guard);

  @override
  String get name => 'edit';

  @override
  String get description =>
      'Replace the unique occurrence of old with new in a workspace file.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path', 'old', 'new'],
        'properties': {
          'path': {'type': 'string'},
          'old': {'type': 'string'},
          'new': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) =>
      requireString(args, 'path') ??
      requireString(args, 'old') ??
      requireString(args, 'new');

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final file = guard.resolve(args['path'] as String);
    if (!file.existsSync()) {
      return ToolOutcome.error('no such file: ${args['path']}');
    }
    final old = args['old'] as String;
    final content = file.readAsStringSync();
    final count = old.allMatches(content).length;
    if (count == 0) return ToolOutcome.error('old text not found');
    if (count > 1) return ToolOutcome.error('old text is not unique ($count)');
    file.writeAsStringSync(content.replaceFirst(old, args['new'] as String));
    return ToolOutcome.ok('edited ${args['path']}');
  }
}

final class RunCommandTool extends Tool implements Cancellable {
  RunCommandTool(super.guard, {this.shell});

  /// Host shell override (tests); defaults to [HostShell.host].
  final HostShell? shell;

  @override
  String get name => 'run_command';

  @override
  String get description =>
      'Run a shell command with the workspace root as its working directory.';

  @override
  Duration get timeout => kBuildTimeout;

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['command'],
        'properties': {
          'command': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) =>
      requireString(args, 'command');

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) => _run(args, null);

  @override
  Future<ToolOutcome> executeCancellable(
          Map<String, dynamic> args, CancelSignal cancel) =>
      _run(args, cancel);

  Future<ToolOutcome> _run(
      Map<String, dynamic> args, CancelSignal? cancel) async {
    if (cancel?.isCancelled ?? false) {
      return const ToolOutcome.error('command cancelled');
    }
    final dir = p.normalize(p.absolute(workspaceRoot));
    final host = shell ?? HostShell.host;
    final (process, grouped) =
        await host.start(args['command'] as String, dir);
    var timedOut = false;
    var cancelled = false;
    // Kill the whole process tree when the host leads one, so a shell that
    // forked its children (a compiler, a test runner) does not leak them; fall
    // back to the direct child otherwise (C8).
    final killer = Timer(timeout, () {
      timedOut = true;
      unawaited(host.killTree(process, grouped));
    });
    cancel?.whenCancelled.then((_) {
      cancelled = true;
      unawaited(host.killTree(process, grouped));
    });
    final output = StringBuffer();
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    void complete(Completer<void> c) {
      if (!c.isCompleted) c.complete();
    }

    process.stdout
        .transform(utf8.decoder)
        .listen(output.write, onDone: () => complete(outDone), onError: (_) {
      complete(outDone);
    });
    process.stderr
        .transform(utf8.decoder)
        .listen(output.write, onDone: () => complete(errDone), onError: (_) {
      complete(errDone);
    });
    final exitCode = await process.exitCode;
    killer.cancel();
    if (cancelled) {
      // The pipes may not close if a child survived an ungrouped kill; return
      // without waiting on them.
      return const ToolOutcome.error('command cancelled');
    }
    if (timedOut) {
      return ToolOutcome.error('command timed out after ${timeout.inSeconds}s');
    }
    await Future.wait([outDone.future, errDone.future]);
    final text = output.toString();
    if (exitCode != 0) {
      return ToolOutcome.error('command exited $exitCode: $text');
    }
    return ToolOutcome.ok(text);
  }
}

final class SearchTool extends Tool {
  SearchTool(super.guard);

  @override
  String get name => 'search';

  @override
  String get description => 'Local regex search over workspace files.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['pattern'],
        'properties': {
          'pattern': {'type': 'string'},
          'path': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) {
    final bad = requireString(args, 'pattern');
    if (bad != null) return bad;
    if (args.containsKey('path') && args['path'] is! String) {
      return 'argument path must be a string';
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final RegExp pattern;
    try {
      pattern = RegExp(args['pattern'] as String);
    } on FormatException catch (e) {
      return ToolOutcome.error('invalid regex: ${e.message}');
    }
    final target = guard.resolve(args['path'] as String? ?? '.');
    final matches = <String>[];
    final List<File> files;
    if (target.existsSync() &&
        target.statSync().type == FileSystemEntityType.file) {
      files = [target];
    } else if (Directory(target.path).existsSync()) {
      files = Directory(target.path)
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
    } else {
      files = <File>[];
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) {
          final relative = p.relative(
            file.path,
            from: p.normalize(p.absolute(workspaceRoot)),
          );
          matches.add('$relative:${i + 1}: ${lines[i]}');
        }
      }
    }
    if (matches.isEmpty) return ToolOutcome.ok('no matches');
    return ToolOutcome.ok(matches.join('\n'));
  }
}
