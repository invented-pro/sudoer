import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cancellation.dart';
import '../errors.dart';
import 'baseline.dart';
import 'job.dart';
import '../models.dart';
import '../platform.dart';
import '../reliability.dart';

/// The workspace anchor (C3). The root is an anchor, not a fence: relative
/// paths resolve against it and `run_command` starts there as its working
/// directory, but paths outside it are ordinary paths — nothing is denied
/// for reaching past it, and the shell is full-trust. The one built-in
/// guard is the network guard ([NetworkGuard]).
final class WorkspaceGuard {
  WorkspaceGuard(this.root);

  final String root;

  File resolve(String path) => File(_resolve(path));

  /// Like [resolve], but for a directory target (glob/search scoping).
  Directory resolveDir(String path) => Directory(_resolve(path));

  String _resolve(String path) {
    final normalizedRoot = p.normalize(p.absolute(root));
    // p.join ignores the root when [path] is already absolute.
    return p.normalize(p.absolute(p.join(normalizedRoot, path)));
  }
}

/// The network egress policy (C3). Enabled and open by default; [denyHosts] is
/// an empty blacklist reserved for later policy. A denial is a hard block with
/// no interactive override. The guard binds only the built-in web tools —
/// `run_command` and `job` are full-trust and can reach any host — so the
/// deny-list is tool-scoped, not host-scoped.
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

/// Validate an optional non-negative integer argument.
String? requireNonNegativeInt(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! int || value < 0) {
    return 'argument $key must be an integer >= 0';
  }
  return null;
}

/// Validate an optional positive integer argument.
String? requirePositiveInt(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! int || value < 1) {
    return 'argument $key must be an integer >= 1';
  }
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

  /// Reap every background job (C3/C8): the run was cancelled or the session
  /// is closing, so no child process outlives the agent.
  Future<void> reapJobs() async {
    final job = tools['job'];
    if (job is JobTool) await job.registry.reapAll();
  }

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

/// The fixed Prop catalog (C3): orientation, read/edit, execution, review and
/// undo, plus the config-gated web tools (assembled separately).
/// [buildTimeout] overrides the `run_command` class timeout (tests).
List<Tool> builtinTools(
  WorkspaceGuard guard, {
  WorkspaceBaseline? baseline,
  JobRegistry? jobs,
  Duration? buildTimeout,
}) =>
    [
      ReadTool(guard),
      WriteTool(guard),
      EditTool(guard),
      MultiEditTool(guard),
      GlobTool(guard),
      RunCommandTool(guard, timeoutOverride: buildTimeout),
      SearchTool(guard),
      JobTool(guard, jobs: jobs),
      DiffTool(guard, baseline: baseline),
      RestoreTool(guard, baseline: baseline),
    ];

/// The built-in tools whose calls are independent and read-only: a step may
/// dispatch them together in parallel (C1). Everything else (write, edit,
/// multi_edit, run_command, job, restore) has side effects or order
/// dependence and runs sequentially in the listed order.
const Set<String> kReadOnlyTools = {
  'read',
  'glob',
  'search',
  'diff',
  'web_fetch',
  'web_search',
};

/// Directories never walked by the workspace-wide tools (glob, search's
/// default scope, and the baseline snapshot backing diff/restore): VCS
/// internals, the agent's own state, and dependency/build trees.
const Set<String> kWorkspaceSkipDirs = {
  '.git',
  '.sudoer',
  '.mise',
  '.dart_tool',
  'node_modules',
  'build',
  'dist',
  '__pycache__',
};

final class ReadTool extends Tool {
  ReadTool(super.guard);

  @override
  String get name => 'read';

  @override
  String get description =>
      'Read a file from the workspace, optionally a line range '
      '(0-based offset, limit lines), returned as text.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path'],
        'properties': {
          'path': {'type': 'string'},
          'offset': {
            'type': 'integer',
            'minimum': 0,
            'description': '0-based line index to start from',
          },
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'description': 'Maximum number of lines to return',
          },
        },
      };

  @override
  String? validate(Map<String, dynamic> args) =>
      requireString(args, 'path') ??
      requireNonNegativeInt(args, 'offset') ??
      requirePositiveInt(args, 'limit');

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final file = guard.resolve(args['path'] as String);
    if (!file.existsSync()) {
      return ToolOutcome.error('no such file: ${args['path']}');
    }
    final content = file.readAsStringSync();
    final offset = args['offset'];
    final limit = args['limit'];
    if (offset is int || limit is int) {
      // A line range returns the requested lines as text, with no line
      // numbers or other prefixes (frozen in the gate contract).
      final lines = file.readAsLinesSync();
      return ToolOutcome.ok(
        lines.skip(offset is int ? offset : 0).take(limit is int ? limit : lines.length).join('\n'),
      );
    }
    return ToolOutcome.ok(content);
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
      'Replace the unique occurrence of old with new in a workspace file; '
      'error if absent or ambiguous. replace_all rewrites every occurrence.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path', 'old', 'new'],
        'properties': {
          'path': {'type': 'string'},
          'old': {'type': 'string'},
          'new': {'type': 'string'},
          'replace_all': {
            'type': 'boolean',
            'description': 'Rewrite every occurrence instead of requiring a '
                'unique match',
          },
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
    final replaceAll = args['replace_all'] == true;
    final content = file.readAsStringSync();
    final count = old.allMatches(content).length;
    if (count == 0) return ToolOutcome.error('old text not found');
    if (count > 1 && !replaceAll) {
      return ToolOutcome.error(
          'old text is ambiguous: $count matches; '
          'pass replace_all to rewrite all of them');
    }
    final updated = replaceAll
        ? content.replaceAll(old, args['new'] as String)
        : content.replaceFirst(old, args['new'] as String);
    file.writeAsStringSync(updated);
    return ToolOutcome.ok(
        'edited ${args['path']} ($count occurrence${count == 1 ? '' : 's'})');
  }
}

/// Apply one ordered batch of edits to a single file, atomically: every edit
/// must match (uniquely, unless replace_all) or nothing is written (C3).
final class MultiEditTool extends Tool {
  MultiEditTool(super.guard);

  @override
  String get name => 'multi_edit';

  @override
  String get description =>
      'Apply an ordered batch of edits to one file in a single step; all '
      'edits are applied to the result of the previous ones, atomically.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['path', 'edits'],
        'properties': {
          'path': {'type': 'string'},
          'edits': {
            'type': 'array',
            'minItems': 1,
            'items': {
              'type': 'object',
              'additionalProperties': false,
              'required': ['old', 'new'],
              'properties': {
                'old': {'type': 'string'},
                'new': {'type': 'string'},
                'replace_all': {'type': 'boolean'},
              },
            },
          },
        },
      };

  @override
  String? validate(Map<String, dynamic> args) {
    final bad = requireString(args, 'path');
    if (bad != null) return bad;
    final edits = args['edits'];
    if (edits is! List || edits.isEmpty) {
      return 'argument edits must be a non-empty array';
    }
    for (final edit in edits) {
      if (edit is! Map) return 'each edit must be an object';
      final map = edit.cast<String, dynamic>();
      final old = requireString(map, 'old');
      if (old != null) return 'edits: $old';
      final replacement = requireString(map, 'new');
      if (replacement != null) return 'edits: $replacement';
    }
    return null;
  }

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final file = guard.resolve(args['path'] as String);
    if (!file.existsSync()) {
      return ToolOutcome.error('no such file: ${args['path']}');
    }
    var content = file.readAsStringSync();
    final edits = (args['edits'] as List).cast<Map<String, dynamic>>();
    // Apply to an in-memory copy; only a fully successful batch is written.
    for (var i = 0; i < edits.length; i++) {
      final edit = edits[i];
      final old = edit['old'] as String;
      final replaceAll = edit['replace_all'] == true;
      final count = old.allMatches(content).length;
      if (count == 0) {
        return ToolOutcome.error(
            'edit ${i + 1}: old text not found; no edits applied');
      }
      if (count > 1 && !replaceAll) {
        return ToolOutcome.error(
            'edit ${i + 1}: old text is ambiguous ($count matches); '
            'no edits applied');
      }
      content = replaceAll
          ? content.replaceAll(old, edit['new'] as String)
          : content.replaceFirst(old, edit['new'] as String);
    }
    file.writeAsStringSync(content);
    return ToolOutcome.ok('edited ${args['path']} (${edits.length} edits)');
  }
}

final class RunCommandTool extends Tool implements Cancellable {
  RunCommandTool(super.guard, {this.shell, this.timeoutOverride});

  /// Host shell override (tests); defaults to [HostShell.host].
  final HostShell? shell;

  /// Class-timeout override (tests); defaults to [kBuildTimeout].
  final Duration? timeoutOverride;

  @override
  String get name => 'run_command';

  @override
  String get description =>
      'Run a shell command with the workspace root as its working directory.';

  @override
  Duration get timeout => timeoutOverride ?? kBuildTimeout;

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

/// Cap on glob results (C3: a compiled-in bound, not configuration).
const int kGlobCap = 500;

final class GlobTool extends Tool {
  GlobTool(super.guard);

  @override
  String get name => 'glob';

  @override
  String get description =>
      'Find workspace paths by glob pattern (for example **/*.dart or '
      'src/*.json), for orientation before editing.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'required': ['pattern'],
        'properties': {
          'pattern': {'type': 'string'},
          'path': {
            'type': 'string',
            'description': 'Directory to search under, workspace-relative',
          },
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
    final pattern = args['pattern'] as String;
    final root = p.normalize(p.absolute(workspaceRoot));
    final scopeDir = guard.resolveDir(args['path'] as String? ?? '.');
    if (!scopeDir.existsSync()) {
      return ToolOutcome.error('no such directory: ${args['path']}');
    }
    final matches = <String>[];
    var capped = false;
    void walk(Directory dir) {
      final entries = dir.listSync(followLinks: false)..sort(
          (a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (entry is Directory) {
          if (kWorkspaceSkipDirs.contains(name)) continue;
          walk(entry);
          continue;
        }
        if (entry is! File) continue;
        final relative = p.posix
            .joinAll(p.relative(entry.path, from: root).split(p.separator));
        if (!globMatch(pattern, relative)) continue;
        if (matches.length >= kGlobCap) {
          capped = true;
          return;
        }
        matches.add(relative);
      }
    }

    walk(scopeDir);
    if (matches.isEmpty) return ToolOutcome.ok('no matches');
    matches.sort();
    return ToolOutcome.ok(capped
        ? '${matches.join('\n')}\n… more than $kGlobCap matches'
        : matches.join('\n'));
  }
}

/// Match [path] (POSIX-style, workspace-relative) against [pattern], where
/// `**` spans any number of directory segments, `*` matches within one
/// segment (never `/`), and `?` matches a single character.
bool globMatch(String pattern, String path) =>
    _segmentsMatch(pattern.split('/'), path.split('/'));

bool _segmentsMatch(List<String> pattern, List<String> path) {
  if (pattern.isEmpty) return path.isEmpty;
  final head = pattern.first;
  if (head == '**') {
    // `**` consumes zero or more path segments.
    for (var skip = 0; skip <= path.length; skip++) {
      if (_segmentsMatch(pattern.sublist(1), path.sublist(skip))) return true;
    }
    return false;
  }
  if (path.isEmpty) return false;
  if (!_segmentMatches(head, path.first)) return false;
  return _segmentsMatch(pattern.sublist(1), path.sublist(1));
}

bool _segmentMatches(String pattern, String segment) {
  var p = 0;
  var s = 0;
  while (p < pattern.length) {
    final char = pattern[p];
    if (char == '*') {
      // Collapse consecutive stars; `*` may end the segment.
      while (p < pattern.length && pattern[p] == '*') {
        p++;
      }
      if (p == pattern.length) return true;
      for (var k = s; k <= segment.length; k++) {
        if (_segmentMatches(pattern.substring(p), segment.substring(k))) {
          return true;
        }
      }
      return false;
    }
    if (s >= segment.length) return false;
    if (char == '?') {
      p++;
      s++;
      continue;
    }
    if (char != segment[s]) return false;
    p++;
    s++;
  }
  return s == segment.length;
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
      // Skip the same trees the other workspace-wide tools skip (VCS
      // internals, the agent's own state, dependency/build trees).
      final found = <File>[];
      void walk(Directory dir) {
        final entries = dir.listSync(followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          if (entry is Directory) {
            if (kWorkspaceSkipDirs.contains(p.basename(entry.path))) continue;
            walk(entry);
          } else if (entry is File) {
            found.add(entry);
          }
        }
      }

      walk(Directory(target.path));
      files = found;
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
