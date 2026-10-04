import 'dart:io';

/// Print the package version from `pubspec.yaml` (the single source of truth)
/// for release naming. Run from the package root.
void main() {
  for (final line in File('pubspec.yaml').readAsLinesSync()) {
    if (line.startsWith('version:')) {
      stdout.write(line.substring('version:'.length).trim());
      return;
    }
  }
  stderr.writeln('version: not found in pubspec.yaml');
  exit(1);
}
