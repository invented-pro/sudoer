import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic.dart';
import 'clock.dart';

/// C11: a user-set scheduled task, frozen in `autonomy.schema.json`
/// (`scheduledTask`). `when` is as set (ISO 8601 or `+<n><m|h|d>`); `nextDue`
/// is the resolved next fire instant.
final class ScheduledTask {
  ScheduledTask({
    required this.id,
    required this.goal,
    this.when,
    this.nextDue,
    this.repeat,
    this.channel,
    this.originChannel,
    this.originFrom,
    this.originSession,
    required this.status,
    required this.created,
    required this.updated,
    this.lastRun,
  });

  final String id;
  final String goal;
  final String? when;
  DateTime? nextDue;
  final String? repeat;

  /// Where the result goes: `notify`, `origin`, or a registered channel id.
  final String? channel;
  final String? originChannel;
  final String? originFrom;
  final String? originSession;
  String status;
  final DateTime created;
  DateTime updated;
  DateTime? lastRun;

  bool get isRecurring => repeat != null && repeat!.isNotEmpty;
  bool get isActive => status == 'pending' || status == 'fired';

  Map<String, dynamic> toJson() => {
        'id': id,
        'goal': goal,
        if (when != null) 'when': when,
        if (nextDue != null) 'next_due': iso8601(nextDue!),
        if (repeat != null) 'repeat': repeat,
        if (channel != null) 'channel': channel,
        if (originChannel != null || originFrom != null)
          'origin': {
            if (originChannel != null) 'channel': originChannel,
            if (originFrom != null) 'from': originFrom,
            if (originSession != null) 'session': originSession,
          },
        'status': status,
        'created': iso8601(created),
        'updated': iso8601(updated),
        if (lastRun != null) 'last_run': iso8601(lastRun!),
      };

  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    final origin = json['origin'] as Map?;
    return ScheduledTask(
      id: json['id'] as String? ?? '',
      goal: json['goal'] as String,
      when: json['when'] as String?,
      nextDue: json['next_due'] == null
          ? null
          : DateTime.parse(json['next_due'] as String),
      repeat: json['repeat'] as String?,
      channel: json['channel'] as String?,
      originChannel: origin?['channel'] as String?,
      originFrom: origin?['from'] as String?,
      originSession: origin?['session'] as String?,
      status: json['status'] as String,
      created: DateTime.parse(json['created'] as String),
      updated: DateTime.parse(json['updated'] as String),
      lastRun: json['last_run'] == null
          ? null
          : DateTime.parse(json['last_run'] as String),
    );
  }

  ScheduledTask copy() => ScheduledTask.fromJson(toJson());
}

/// One fire (`autonomy.schema.json` `fireRecord`), written *before* the run
/// starts — the idempotency key is `(task, due)` (C8/C11).
final class FireRecord {
  FireRecord({required this.task, required this.due, required this.at, this.outcome});

  final String task;
  final DateTime due;

  /// When the record was (re)written; mutable so the completion of a fire
  /// updates its `started` line in place.
  DateTime at;
  String? outcome;

  String get key => '$task\u0000${due.toIso8601String()}';

  Map<String, dynamic> toJson() => {
        'task': task,
        'due': iso8601(due),
        'at': iso8601(at),
        'outcome': ?outcome,
      };

  factory FireRecord.fromJson(Map<String, dynamic> json) => FireRecord(
        task: json['task'] as String,
        due: DateTime.parse(json['due'] as String),
        at: DateTime.parse(json['at'] as String),
        outcome: json['outcome'] as String?,
      );
}

/// The durable task store (`tasks_file`). Reloaded from disk on every
/// mutation cycle, so the service, a CLI session, and a wake `tick` share
/// one truth; every write is atomic (C8).
final class TaskStore {
  TaskStore(this.path, this.clock);

  final String path;
  final Clock clock;

  final List<FireRecord> fires = [];

  /// Load every task, migrating a legacy `reminders.json` on read (C11).
  List<ScheduledTask> load() {
    _migrateLegacy();
    final json = readJson(path);
    if (json == null) return [];
    final tasks = json['tasks'];
    if (tasks is! List) return [];
    fires
      ..clear()
      ..addAll([
        for (final fire in (json['fires'] as List? ?? const []))
          FireRecord.fromJson((fire as Map).cast<String, dynamic>()),
      ]);
    return [
      for (final task in tasks)
        ScheduledTask.fromJson((task as Map).cast<String, dynamic>()),
    ];
  }

  /// A legacy `reminders.json` (C11 v0.1) beside the tasks file is migrated
  /// once: a reminder is a one-shot task.
  void _migrateLegacy() {
    if (File(path).existsSync()) return;
    final legacy = File(p.join(p.dirname(path), 'reminders.json'));
    if (!legacy.existsSync()) return;
    final decoded = jsonDecode(legacy.readAsStringSync());
    final items = decoded is List ? decoded : (decoded['reminders'] as List?);
    if (items == null) return;
    final now = clock.now();
    save([
      for (final item in items)
        ScheduledTask(
          id: (item as Map)['id'] as String,
          goal: item['goal'] as String,
          when: item['when'] as String?,
          nextDue: item['next_due'] == null
              ? null
              : DateTime.parse(item['next_due'] as String),
          status: 'pending',
          created: now,
          updated: now,
        ),
    ]);
    legacy.renameSync('${legacy.path}.migrated');
  }

  /// Persist the store atomically; fires ride along so idempotency survives
  /// a crash (C11).
  void save(List<ScheduledTask> tasks) {
    atomicWrite(
        path,
        jsonEncode({
          'tasks': [for (final task in tasks) task.toJson()],
          'fires': [for (final fire in fires) fire.toJson()],
        }));
  }

  /// True when this `(task, due)` has already been fired — the idempotency
  /// check a redundant wake or duplicate tick cannot pass twice (C8/C11).
  bool hasFired(FireRecord record) =>
      fires.any((fire) => fire.key == record.key);

  /// Record a fire *before* its run starts and persist at once (C11). The
  /// key is `(task, due)`: a later record for the same key — the `done`
  /// outcome after the run, say — updates the existing line rather than
  /// appending a second one, so one fire is one record.
  void recordFire(FireRecord record, List<ScheduledTask> tasks) {
    final existing = fires.indexWhere((fire) => fire.key == record.key);
    if (existing >= 0) {
      fires[existing]
        ..at = record.at
        ..outcome = record.outcome;
    } else {
      fires.add(record);
    }
    save(tasks);
  }
}

/// The ISO 8601 wire form the schemas' examples use: second precision with
/// a `Z` suffix; sub-second precision appears only when it is non-zero.
String iso8601(DateTime time) {
  final t = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final base = '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-'
      '${two(t.day)}T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  if (t.millisecond == 0 && t.microsecond == 0) return '${base}Z';
  final millis = t.millisecond.toString().padLeft(3, '0');
  return '$base.${millis}Z';
}

/// Resolve a `when` value: ISO 8601, or a relative `+<n><m|h|d>` against
/// [now] (C11). Null when the shape is not recognized.
DateTime? resolveWhen(String when, DateTime now) {
  final relative = RegExp(r'^\+(\d+)([mhd])$').firstMatch(when);
  if (relative != null) {
    final n = int.parse(relative.group(1)!);
    return switch (relative.group(2)) {
      'm' => now.add(Duration(minutes: n)),
      'h' => now.add(Duration(hours: n)),
      _ => now.add(Duration(days: n)),
    };
  }
  try {
    return DateTime.parse(when);
  } on FormatException {
    return null;
  }
}

/// The next due instant after [from] for a `repeat` expression:
/// `+<n><m|h|d>`, `daily@HH:MM`, or `weekly@<mon..sun>@HH:MM` (C11).
/// Null for an unrecognized recurrence.
DateTime? advanceRepeat(String repeat, DateTime from) {
  final relative = RegExp(r'^\+(\d+)([mhd])$').firstMatch(repeat);
  if (relative != null) {
    final n = int.parse(relative.group(1)!);
    return switch (relative.group(2)) {
      'm' => from.add(Duration(minutes: n)),
      'h' => from.add(Duration(hours: n)),
      _ => from.add(Duration(days: n)),
    };
  }
  final daily = RegExp(r'^daily@(\d{1,2}):(\d{2})$').firstMatch(repeat);
  if (daily != null) {
    final next = DateTime.utc(from.year, from.month, from.day,
        int.parse(daily.group(1)!), int.parse(daily.group(2)!));
    return next.isAfter(from) ? next : next.add(const Duration(days: 1));
  }
  final weekly =
      RegExp(r'^weekly@([a-z]+)@(\d{1,2}):(\d{2})$').firstMatch(repeat);
  if (weekly != null) {
    const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final target = days.indexOf(weekly.group(1)!);
    if (target < 0) return null;
    var next = DateTime.utc(from.year, from.month, from.day,
        int.parse(weekly.group(2)!), int.parse(weekly.group(3)!));
    // DateTime.weekday: Monday = 1 .. Sunday = 7.
    var delta = (target + 1) - from.weekday;
    if (delta < 0 || (delta == 0 && !next.isAfter(from))) delta += 7;
    next = next.add(Duration(days: delta));
    return next;
  }
  return null;
}
