import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Portable build: compile the Prop agent to a native executable, publish it
/// to the eval instance, and stage a version-stamped release asset. It uses
/// only Dart APIs, so it runs on Linux, macOS, and Windows. Dart does not
/// cross-compile — each host builds its own binary.
Future<void> main() async {
  final version = _pubspecVersion();
  final exe = Platform.isWindows ? 'sudoer-prop.exe' : 'sudoer-prop';
  final dist = Directory('dist')..createSync(recursive: true);
  final output = p.join(dist.path, exe);

  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'compile', 'exe', 'bin/sudoer.dart', '-o', output,
      // Build identity (lib/src/build_info.dart): the pubspec version is the
      // single source of truth, so it is injected as a define rather than
      // duplicated; the repo URL keeps its compile-time default.
      '-DSUDOER_VERSION=$version',
    ],
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) exit(result.exitCode);

  // Publish the runnable to the eval instance via a temp file and an atomic
  // rename, so replacing a binary that is still running does not fail with
  // "text file busy".
  final published = p.join('..', '..', '20_eval', 'agent_prop', exe);
  _replace(File(output), File(published));

  // Stage a release directory in 90_dist/: the archive (built by CI) carries
  // the full metadata in its name, while the executable inside keeps the short
  // name the user types.
  final release = p.join(
      '..', '..', '90_dist', 'sudoer-prop-$version-${_os()}-${_arch()}');
  Directory(release).createSync(recursive: true);
  File(output).copySync(p.join(release, exe));

  stdout.writeln('version $version');
  stdout.writeln('built $output -> $published');
  stdout.writeln('release $release${Platform.pathSeparator}$exe');
}

/// Copy [source] over [target] via a temp file and an atomic rename.
void _replace(File source, File target) {
  target.parent.createSync(recursive: true);
  final temp = File(p.join(target.parent.path, '.sudoer.tmp'));
  source.copySync(temp.path);
  temp.renameSync(target.path);
}

String _pubspecVersion() {
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
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
