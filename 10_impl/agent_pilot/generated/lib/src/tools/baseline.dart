import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../platform.dart';
import 'tool.dart';

/// Cap on a single file snapshotted into a baseline (C3): larger files are
/// recorded as opaque (present, but neither diffable nor restorable).
const int kBaselineMaxFileBytes = 1024 * 1024;

/// Cap on the total bytes of content a baseline snapshots; files past it are
/// recorded as opaque so capture stays bounded on huge workspaces.
const int kBaselineMaxTotalBytes = 32 * 1024 * 1024;

/// Lines beyond which a per-file diff falls back to a whole-file replacement
/// summary instead of a line diff.
const int kDiffMaxLines = 2000;

/// C3/C5: the workspace snapshot backing `diff` and `restore`. Captured once
/// when a session opens and refreshed only when the workspace root changes;
/// the session records its opaque handle (the store file's name). Never shown
/// to the model; not the transcript.
final class WorkspaceBaseline {
  WorkspaceBaseline._(this.root, this.files, this.capturedAt);

  /// Absolute workspace root the snapshot was taken under.
  final String root;

  /// Workspace-relative path -> file contents at capture. A null value is an
  /// opaque entry: the file was present but not snapshotted (binary or over
  /// the size caps), so it can be listed but neither diffed nor restored.
  final Map<String, String?> files;

  final DateTime capturedAt;

  /// The opaque handle recorded in the session file (C5).
  String get handle => '$rootHandleToken.baseline.json';

  // The handle is derived from the root so a changed workspace cannot
  // silently reuse another root's snapshot.
  String get rootHandleToken => _tokenize(p.basename(root));

  static String _tokenize(String name) {
    final clean = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return clean.isEmpty ? 'workspace' : clean;
  }

  /// Absolute path of a workspace-relative snapshot entry.
  String _absolute(String relative) =>
      p.joinAll([root, ...relative.split('/')]);

  /// Walk [root] and snapshot its text files, skipping the trees the other
  /// workspace-wide tools skip (VCS internals, agent state, dependency and
  /// build trees).
  static WorkspaceBaseline capture(String root) {
    final absRoot = p.normalize(p.absolute(root));
    final files = <String, String?>{};
    var total = 0;
    void walk(Directory dir) {
      final entries = dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        if (entry is Directory) {
          if (kWorkspaceSkipDirs.contains(p.basename(entry.path))) continue;
          walk(entry);
          continue;
        }
        if (entry is! File) continue;
        final relative =
            p.posix.joinAll(p.relative(entry.path, from: absRoot).split(p.separator));
        final size = entry.lengthSync();
        if (size > kBaselineMaxFileBytes || total >= kBaselineMaxTotalBytes) {
          files[relative] = null;
          continue;
        }
        final bytes = entry.readAsBytesSync();
        if (bytes.contains(0)) {
          // Binary: record identity only.
          files[relative] = null;
          continue;
        }
        total += bytes.length;
        files[relative] = utf8.decode(bytes, allowMalformed: true);
      }
    }

    if (Directory(absRoot).existsSync()) walk(Directory(absRoot));
    return WorkspaceBaseline._(absRoot, files, DateTime.now().toUtc());
  }

  /// Persist the snapshot next to the session file; returns the handle.
  String save(String sessionDir) {
    Directory(sessionDir).createSync(recursive: true);
    File(p.join(sessionDir, handle))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
    return handle;
  }

  /// Load a snapshot by [handle] from [sessionDir], or null when absent.
  static WorkspaceBaseline? load(String sessionDir, String handle) {
    final file = File(p.join(sessionDir, handle));
    if (!file.existsSync()) return null;
    final Map<String, dynamic> json;
    try {
      json = (jsonDecode(file.readAsStringSync()) as Map).cast<String, dynamic>();
    } on FormatException {
      return null;
    }
    final raw = (json['files'] as Map).cast<String, dynamic>();
    return WorkspaceBaseline._(
      json['root'] as String,
      {for (final entry in raw.entries) entry.key: entry.value as String?},
      DateTime.parse(json['captured_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'root': root,
        'captured_at': capturedAt.toIso8601String(),
        'files': files,
      };

  /// The workspace-relative paths that currently exist under [root], using
  /// the same skip set as [capture].
  Map<String, String?> current() {
    final absRoot = p.normalize(p.absolute(root));
    final current = <String, String?>{};
    void walk(Directory dir) {
      for (final entry in dir.listSync(followLinks: false)) {
        if (entry is Directory) {
          if (kWorkspaceSkipDirs.contains(p.basename(entry.path))) continue;
          walk(entry);
          continue;
        }
        if (entry is! File) continue;
        current[p.posix
            .joinAll(p.relative(entry.path, from: absRoot).split(p.separator))] = null;
      }
    }

    if (Directory(absRoot).existsSync()) walk(Directory(absRoot));
    return current;
  }

  /// A short unified-style diff of the workspace against this baseline:
  /// per-file line diffs for text snapshots, and add/remove/unknown notes for
  /// everything else. Empty string when nothing changed.
  String diffWorkspace({String? only}) {
    final buffer = StringBuffer();
    final now = current();
    final paths = <String>{...files.keys, ...now.keys}.toList()..sort();
    for (final relative in paths) {
      if (only != null && relative != only) continue;
      final before = files[relative];
      final existsNow = now.containsKey(relative);
      if (before == null && files.containsKey(relative) && !existsNow) {
        buffer.writeln('- $relative (deleted)');
        continue;
      }
      if (!files.containsKey(relative)) {
        if (existsNow) buffer.writeln('+ $relative (new file)');
        continue;
      }
      if (!existsNow) {
        buffer.writeln('- $relative (deleted)');
        continue;
      }
      if (before == null) {
        buffer.writeln('~ $relative (present at capture but not snapshotted; '
            'content unknown)');
        continue;
      }
      final after = File(_absolute(relative)).readAsStringSync();
      if (after == before) continue;
      buffer.writeln('~ $relative');
      buffer.write(_lineDiff(before, after));
    }
    return buffer.toString().trimRight();
  }

  /// A compact line diff: `- ` for removed lines, `+ ` for added ones, in
  /// order, via a longest-common-subsequence match. Large inputs fall back to
  /// whole-file before/after.
  static String _lineDiff(String before, String after) {
    final a = before.split('\n');
    final b = after.split('\n');
    if (a.length > kDiffMaxLines || b.length > kDiffMaxLines) {
      return '- (whole file replaced; ${a.length} -> ${b.length} lines)\n';
    }
    // LCS table (guarded by the caps above).
    final lcs = List.generate(
        a.length + 1, (_) => List<int>.filled(b.length + 1, 0),
        growable: false);
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        lcs[i][j] = a[i] == b[j]
            ? lcs[i + 1][j + 1] + 1
            : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    final out = StringBuffer();
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        out.writeln('- ${a[i++]}');
      } else {
        out.writeln('+ ${b[j++]}');
      }
    }
    while (i < a.length) {
      out.writeln('- ${a[i++]}');
    }
    while (j < b.length) {
      out.writeln('+ ${b[j++]}');
    }
    return out.toString();
  }

  /// Revert [relative] (or every changed file when null) to this baseline.
  /// Returns a human-readable report of what was reverted. Files not in the
  /// baseline are removed; opaque entries are reported, not touched.
  String restore({String? relative}) {
    final now = current();
    final reverted = <String>[];
    final removed = <String>[];
    final skipped = <String>[];
    void restoreOne(String rel) {
      final before = files[rel];
      if (!files.containsKey(rel)) {
        final target = File(_absolute(rel));
        if (now.containsKey(rel) && target.existsSync()) {
          target.deleteSync();
          removed.add(rel);
        }
        return;
      }
      if (before == null) {
        skipped.add(rel);
        return;
      }
      final target = File(_absolute(rel));
      if (!target.existsSync() || target.readAsStringSync() != before) {
        target
          ..createSync(recursive: true)
          ..writeAsStringSync(before);
        reverted.add(rel);
      }
    }

    if (relative != null) {
      restoreOne(relative);
    } else {
      final paths = <String>{...files.keys, ...now.keys}.toList()..sort();
      for (final rel in paths) {
        restoreOne(rel);
      }
    }
    final parts = <String>[
      if (reverted.isNotEmpty) 'restored ${reverted.length} file(s)',
      if (removed.isNotEmpty) 'removed ${removed.length} file(s)',
      if (skipped.isNotEmpty)
        'not snapshotted (left unchanged): ${skipped.take(5).join(', ')}'
        '${skipped.length > 5 ? ', …' : ''}',
    ];
    return parts.isEmpty ? 'nothing to restore' : parts.join('; ');
  }
}

/// diff (C3): show the workspace's uncommitted changes against the session
/// baseline; falls back to the underlying VCS when no baseline is recorded.
final class DiffTool extends Tool {
  DiffTool(super.guard, {this.baseline});

  final WorkspaceBaseline? baseline;

  @override
  String get name => 'diff';

  @override
  String get description =>
      'Show the workspace\'s uncommitted changes against the baseline captured '
      'when the session opened; pass path to scope to one file.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'path': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) =>
      args.containsKey('path') && args['path'] is! String
          ? 'argument path must be a string'
          : null;

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final String? scope = args['path'] as String?;
    final baseline = this.baseline;
    if (baseline == null) {
      return _vcsDiff(scope);
    }
    final text = baseline.diffWorkspace(
        only: scope == null
            ? null
            : p.posix.joinAll(p
                .relative(guard.resolve(scope).path,
                    from: p.normalize(p.absolute(workspaceRoot)))
                .split(p.separator)));
    return ToolOutcome.ok(text.isEmpty ? 'no changes' : text);
  }

  /// No baseline recorded (e.g. a legacy session): ask the workspace's VCS
  /// for the same information (C3).
  Future<ToolOutcome> _vcsDiff(String? scope) async {
    final root = p.normalize(p.absolute(workspaceRoot));
    if (!Directory(p.join(root, '.git')).existsSync()) {
      return ToolOutcome.error('no session baseline and no .git directory; '
          'cannot diff');
    }
    final host = HostShell.host;
    final (process, _) = await host.start(
      'git --no-pager diff HEAD --${scope ?? '.'} && '
      'git --no-pager status --porcelain',
      root,
    );
    final output = StringBuffer();
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    void finish(Completer<void> c) {
      if (!c.isCompleted) c.complete();
    }

    process.stdout.transform(utf8.decoder).listen(output.write,
        onDone: () => finish(outDone), onError: (_) => finish(outDone));
    process.stderr.transform(utf8.decoder).listen(output.write,
        onDone: () => finish(errDone), onError: (_) => finish(errDone));
    final code = await process.exitCode;
    await Future.wait([outDone.future, errDone.future]);
    final text = output.toString().trim();
    if (code != 0) {
      return ToolOutcome.error('git diff exited $code: $text');
    }
    return ToolOutcome.ok(text.isEmpty ? 'no changes' : text);
  }
}

/// restore (C3): revert files to the session baseline.
final class RestoreTool extends Tool {
  RestoreTool(super.guard, {this.baseline});

  final WorkspaceBaseline? baseline;

  @override
  String get name => 'restore';

  @override
  String get description =>
      'Revert files to the baseline captured when the session opened; pass '
      'path to restore one file, omit it to restore every changed file.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'path': {'type': 'string'},
        },
      };

  @override
  String? validate(Map<String, dynamic> args) =>
      args.containsKey('path') && args['path'] is! String
          ? 'argument path must be a string'
          : null;

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> args) async {
    final baseline = this.baseline;
    if (baseline == null) {
      return ToolOutcome.error('no session baseline to restore against');
    }
    final String? scope = args['path'] as String?;
    if (scope == null) {
      return ToolOutcome.ok(baseline.restore());
    }
    final file = guard.resolve(scope);
    if (!file.existsSync() && !baseline.files.containsKey(scope)) {
      return ToolOutcome.error('no such file: $scope');
    }
    final relative = p.posix.joinAll(p
        .relative(file.path, from: p.normalize(p.absolute(workspaceRoot)))
        .split(p.separator));
    return ToolOutcome.ok('${baseline.restore(relative: relative)} ($scope)');
  }
}
