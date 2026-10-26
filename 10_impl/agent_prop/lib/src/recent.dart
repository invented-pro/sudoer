import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';

/// One provider/model pair the user actually ran with.
final class RecentModel {
  const RecentModel({required this.preset, required this.model});

  final String preset;
  final String model;

  Map<String, dynamic> toJson() => {'preset': preset, 'model': model};

  factory RecentModel.fromJson(Map<String, dynamic> json) => RecentModel(
    preset: json['preset'] as String,
    model: json['model'] as String,
  );

  @override
  bool operator ==(Object other) =>
      other is RecentModel && other.preset == preset && other.model == model;

  @override
  int get hashCode => Object.hash(preset, model);
}

/// The default recents file: `<app dir>/recent.json`, beside the sessions
/// store, so it follows `SUDOER_HOME`/XDG like everything else.
String defaultRecentPath() => p.join(defaultAppDir(), 'recent.json');

/// C2/C5: the provider/model pairs actually used, most recent first, kept in
/// `<app dir>/recent.json` so the `/model` picker can offer one-pick returns
/// to previous combos across sessions. Recording a pair moves it to the
/// front, de-duplicates, and caps the list at [limit]. Recents are a
/// convenience: a missing or corrupt file reads as empty, and a failed write
/// is skipped, never fatal.
final class RecentModels {
  RecentModels({String? path, this.limit = 8}) : path = path ?? defaultRecentPath();

  /// Where the pairs are stored.
  final String path;

  /// The most pairs kept.
  final int limit;

  List<RecentModel> read() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map &&
              entry['preset'] is String &&
              (entry['preset'] as String).isNotEmpty &&
              entry['model'] is String &&
              (entry['model'] as String).isNotEmpty)
            RecentModel.fromJson(entry.cast<String, dynamic>()),
      ];
    } on Object {
      return const [];
    }
  }

  /// Move [preset]/[model] to the front of the list and persist it.
  void record(String preset, String model) {
    final entry = RecentModel(preset: preset, model: model);
    final next = [entry, ...read().where((e) => e != entry)].take(limit);
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final temp = File('$path.tmp');
      temp.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert([
          for (final item in next) item.toJson(),
        ])}\n',
      );
      // Windows rename does not replace an existing destination.
      if (Platform.isWindows && file.existsSync()) file.deleteSync();
      temp.renameSync(path);
    } on Object {
      // A read-only home or a full disk must not break a provider switch.
    }
  }
}
