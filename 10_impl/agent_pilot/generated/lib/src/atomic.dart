import 'dart:convert';
import 'dart:io';

/// C8/C9/C11: every shared store is written atomically — a temp file in the
/// same directory, renamed over the target — so a concurrent reader never
/// sees a torn record (C5, C8).
void atomicWrite(String path, String contents) {
  final target = File(path);
  final parent = target.parent;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  final temp = File(
      '${target.path}.tmp${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}');
  temp.writeAsStringSync(contents);
  temp.renameSync(target.path);
}

/// Read and decode a JSON file, or null when it does not exist. A malformed
/// file is a [FormatException] for the caller to surface, never silently
/// ignored (C9: a broken store is reported, not guessed at).
dynamic readJson(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return jsonDecode(file.readAsStringSync());
}
