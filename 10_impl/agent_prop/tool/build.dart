import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Portable build: compile the Prop agent to a native executable into the
/// versioned release in 90_dist/ — the single home of final builds — and
/// expose it to the eval instance and the package itself through relative
/// symlinks. It uses only Dart APIs, so it runs on Linux, macOS, and
/// Windows. Dart does not cross-compile — each host builds its own binary.
/// On Windows, where symlinks need privileges, the links fall back to copies.
Future<void> main() async {
  // Anchor every path at this script's package root, not the CWD, so
  // the tool works from any directory.
  final pkg = _packageRoot();
  final version = _pubspecVersion(pkg);
  final repo = p.dirname(p.dirname(pkg));
  final exe = Platform.isWindows ? 'sudoer-prop.exe' : 'sudoer-prop';

  // Compile straight into the versioned release directory (90_dist/): the
  // archive (built by CI) carries the full metadata in its name, while the
  // executable inside keeps the short name the user types.
  final release = p.join(
      repo, '90_dist', 'sudoer-prop-$version-${_os()}-${_arch()}');
  Directory(release).createSync(recursive: true);
  final output = p.join(release, exe);

  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'compile', 'exe', p.join(pkg, 'bin', 'sudoer.dart'), '-o', output,
      // Build identity (lib/src/build_info.dart): the pubspec version is the
      // single source of truth, so it is injected as a define rather than
      // duplicated; the repo URL keeps its compile-time default.
      '-DSUDOER_VERSION=$version',
    ],
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);

  // 10_impl and 20_eval call the executable through symlinks into 90_dist/,
  // re-pointed on every build (the version directory name changes).
  _link(output, p.join(repo, '20_eval', 'agent_prop', exe));
  _link(output, p.join(pkg, exe));

  stdout.writeln('version $version');
  stdout.writeln('built $output');
}

/// This script lives in `<pkg>/tool/` — the package root is its parent,
/// found from the script location so the CWD never matters.
String _packageRoot() {
  var dir = File(p.fromUri(Platform.script)).parent; // tool/
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not locate pubspec.yaml upward from tool/');
    }
    dir = parent;
  }
}

/// Point [linkPath] at [source] with a relative symlink, replacing whatever
/// stands there (an older link or a copied binary from the copy era). Where
/// symlinks need privileges (Windows), falls back to a copy.
void _link(String source, String linkPath) {
  final existing = FileSystemEntity.typeSync(linkPath, followLinks: false);
  if (existing == FileSystemEntityType.link) {
    Link(linkPath).deleteSync();
  } else if (existing != FileSystemEntityType.notFound) {
    File(linkPath).deleteSync();
  }
  try {
    Link(linkPath).createSync(
        p.relative(p.absolute(source), from: p.absolute(p.dirname(linkPath))));
  } on FileSystemException {
    File(source).copySync(linkPath);
  }
  stdout.writeln('linked $linkPath -> $source');
}

String _pubspecVersion(String pkg) {
  for (final line in File(p.join(pkg, 'pubspec.yaml')).readAsLinesSync()) {
    if (line.startsWith('version:')) {
      return line.substring('version:'.length).trim();
    }
  }
  throw StateError('version not found in pubspec.yaml');
}

String _os() => Platform.isWindows
    ? 'windows'
    : Platform.isMacOS
        ? 'macos'
        : Platform.isLinux
            ? 'linux'
            : Platform.operatingSystem;

String _arch() {
  final abi = Abi.current();
  if (abi == Abi.macosArm64 || abi == Abi.linuxArm64) return 'arm64';
  if (abi == Abi.macosX64 || abi == Abi.linuxX64 || abi == Abi.windowsX64) {
    return 'x64';
  }
  return abi.toString().split('.').last;
}
