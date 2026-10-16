import '../models.dart';
import '../pilot_config.dart';

import '../scheduler.dart';
import '../session.dart';
import 'task.dart';

/// The expected result of one goal run (Prop fields + Pilot's `reason`).
final class RunExpect {
  const RunExpect({
    this.status,
    this.answerEquals,
    this.answerContains,
    this.reason,
  });

  final RunStatus? status;
  final String? answerEquals;
  final String? answerContains;
  final String? reason;
}

/// One channel-delivery expectation (substrings, in order).
final class ChannelExpect {
  const ChannelExpect({this.channel, this.to, this.message});
  final String? channel;
  final String? to;
  final String? message;
}

/// One notification expectation.
final class NotificationExpect {
  const NotificationExpect({this.title, this.message});
  final String? title;
  final String? message;
}

/// One expected scheduled-task state, keyed by a goal substring.
final class TaskExpect {
  const TaskExpect({
    required this.goalSubstring,
    required this.status,
    this.nextDue,
    this.repeat,
  });
  final String goalSubstring;
  final String status;
  final String? nextDue;
  final String? repeat;
}

/// One expected JSONL log line (kind plus optional fields), in order.
final class LogExpect {
  const LogExpect({required this.kind, this.tool, this.detail, this.status});
  final String kind;
  final String? tool;
  final String? detail;
  final String? status;
}

/// One expected policy-decision line, in order.
final class PolicyExpect {
  const PolicyExpect({required this.event, required this.tool, this.detail});
  final String event;
  final String tool;
  final String? detail;
}

/// One API-driver step.
sealed class ApiStep {
  const ApiStep();
}

final class CreateSessionStep extends ApiStep {
  const CreateSessionStep(this.name);
  final String name;
}

final class RunStep extends ApiStep {
  const RunStep(this.session, this.goal);
  final String session;
  final String goal;
}

final class GetConfigStep extends ApiStep {
  const GetConfigStep();
}

final class PutConfigStep extends ApiStep {
  const PutConfigStep(this.patch);
  final Map<String, dynamic> patch;
}

final class LoginStep extends ApiStep {
  const LoginStep(this.token);
  final String token;
}

/// One clock advance / scheduler tick instruction, in order.
final class Tick {
  const Tick.advance(this.advance) : tick = false;
  const Tick.fire() : advance = null, tick = true;
  final String? advance;
  final bool tick;
}

/// The expected observable outcome of a Pilot gate task: every Prop
/// expectation plus the Pilot extensions (task-pilot.schema.json).
final class PilotExpect {
  const PilotExpect({
    this.status,
    this.answerEquals,
    this.answerContains,
    this.answerNotContains,
    this.files,
    this.tools,
    this.observations,
    this.runs = const [],
    this.plan,
    this.sessionPersisted,
    this.stdoutContains,
    this.prefixStable,
    this.memory,
    this.recall,
    this.embeddingsRebuilt,
    this.embeddingsModel,
    this.embeddingsIds,
    this.tasks = const [],
    this.fired = const [],
    this.channels = const [],
    this.scheduler = const [],
    this.api = const [],
    this.notifications = const [],
    this.logs = const [],
    this.policy = const [],
    this.reason,
  });

  final RunStatus? status;
  final String? answerEquals;
  final String? answerContains;
  final String? answerNotContains;
  final Map<String, String>? files;
  final List<String>? tools;
  final List<String>? observations;
  final List<RunExpect> runs;
  final List<String>? plan;
  final bool? sessionPersisted;
  final String? stdoutContains;
  final bool? prefixStable;

  /// Expected memory notes by id: each value a substring of the body.
  final Map<String, String>? memory;

  /// Memory ids expected injected into the first prompt of a goal.
  final List<String>? recall;

  /// The embedding index assertions.
  final bool? embeddingsRebuilt;
  final String? embeddingsModel;
  final List<String>? embeddingsIds;

  /// Expected scheduled tasks by goal substring.
  final List<TaskExpect> tasks;

  /// The ordered fire log; each `{task, due}` appears once.
  final List<PilotFireRecord> fired;

  /// Recorded outbound channel deliveries (substrings, in order).
  final List<ChannelExpect> channels;

  /// The OS wake units/paths the fake scheduler captured.
  final List<String> scheduler;

  /// Expected API-driver step results, in order.
  final List<Map<String, dynamic>> api;
  final List<NotificationExpect> notifications;
  final List<LogExpect> logs;
  final List<PolicyExpect> policy;
  final String? reason;
}

/// One Pilot gate task: the Prop task shape extended with the Pilot harness
/// knobs (task-pilot.schema.json). Self-contained; built from JSON.
final class PilotTask {
  PilotTask({
    required this.id,
    required this.turns,
    required this.workspace,
    required this.configOverride,
    required this.scripts,
    required this.expect,
    this.secrets = const {},
    this.seedTasks = const [],
    this.embedderMode,
    this.registerChannels = const [],
    this.inbound = const [],
    this.ticks = const [],
    this.clockNow,
    this.stubs = const [],
    this.api,
    this.hostShellPosix = false,
  });

  final String id;
  final List<Turn> turns;
  final Map<String, String> workspace;
  final Map<String, dynamic> configOverride;

  /// The scripted chain: one entry per provider; a single-entry list is the
  /// `script` sugar (gate.md: `scripts` ordered, else `script`).
  final List<Map<String, dynamic>> scripts;

  final Map<String, String> secrets;
  final List<Map<String, dynamic>> seedTasks;
  final String? embedderMode;

  /// Channels registered before driving, and inbound messages delivered.
  final List<Map<String, dynamic>> registerChannels;
  final List<({String channel, String from, String text})> inbound;

  final List<Tick> ticks;
  final DateTime? clockNow;

  /// Loopback canned responders, in declaration order.
  final List<({String name, int status, Map<String, String> headers, String body})>
      stubs;

  final ({List<ApiStep> steps})? api;
  final bool hostShellPosix;

  final PilotExpect expect;

  /// The session the drive ended on (set by the runner; harness-level state
  /// expectations need it).
  Session? lastSession;

  /// The runs the drive produced (set by the runner; API tasks project the
  /// served sessions' runs here).
  List<RunResult> runs = [];

  factory PilotTask.fromJson(Map<String, dynamic> json) {
    final turns = <Turn>[];
    final rawTurns = json['turns'] as List?;
    if (rawTurns != null) {
      for (final turn in rawTurns) {
        final map = (turn as Map).cast<String, dynamic>();
        if (map.containsKey('goal')) {
          turns.add(Turn.goal(map['goal'] as String));
        } else {
          turns.add(Turn.command(map['command'] as String));
        }
      }
    } else if (json['goal'] != null) {
      turns.add(Turn.goal(json['goal'] as String));
    }

    // `scripts` (ordered chain) or `script` (single provider).
    final scripts = <Map<String, dynamic>>[
      if (json['scripts'] is List)
        for (final script in json['scripts'] as List)
          (script as Map).cast<String, dynamic>()
      else if (json['script'] != null)
        (json['script'] as Map).cast<String, dynamic>(),
    ];

    final channels = json['channels'] as Map?;
    final inbound = <({String channel, String from, String text})>[
      for (final message in (channels?['inbound'] as List? ?? const []))
        (
          channel: (message as Map)['channel'] as String,
          from: message['from'] as String,
          text: message['text'] as String,
        ),
    ];
    final register = <Map<String, dynamic>>[
      for (final channel in (channels?['register'] as List? ?? const []))
        (channel as Map).cast<String, dynamic>(),
    ];

    final ticks = <Tick>[];
    for (final tick in (json['ticks'] as List? ?? const [])) {
      final map = (tick as Map).cast<String, dynamic>();
      if (map['advance'] != null) {
        ticks.add(Tick.advance(map['advance'] as String));
      } else if (map['tick'] == true) {
        ticks.add(const Tick.fire());
      }
    }

    final clock = json['clock'] as Map?;
    final stubs =
        <({String name, int status, Map<String, String> headers, String body})>[
      for (final stub in (json['stubs'] as List? ?? const []))
        (
          name: (stub as Map)['name'] as String,
          status: stub['response']['status'] as int,
          headers: {
            for (final entry
                in ((stub['response']['headers'] as Map?) ?? const {})
                    .entries)
              entry.key as String: entry.value as String,
          },
          body: stub['response']['body'] as String,
        ),
    ];

    final api = json['api'] as Map?;
    final apiSteps = <ApiStep>[];
    if (api != null) {
      for (final step in (api['steps'] as List)) {
        final map = (step as Map).cast<String, dynamic>();
        if (map.containsKey('createSession')) {
          apiSteps.add(CreateSessionStep(map['createSession'] as String));
        } else if (map.containsKey('run')) {
          apiSteps.add(RunStep(map['run'] as String, map['goal'] as String));
        } else if (map.containsKey('getConfig')) {
          apiSteps.add(const GetConfigStep());
        } else if (map.containsKey('putConfig')) {
          apiSteps.add(PutConfigStep(
              (map['putConfig'] as Map).cast<String, dynamic>()));
        } else if (map.containsKey('login')) {
          apiSteps.add(LoginStep(map['login'] as String));
        }
      }
    }

    return PilotTask(
      id: json['id'] as String,
      turns: turns,
      workspace: {
        for (final entry in ((json['workspace'] as Map?) ?? {}).entries)
          entry.key as String: entry.value as String,
      },
      configOverride:
          ((json['config'] as Map?) ?? {}).cast<String, dynamic>(),
      scripts: scripts,
      secrets: {
        for (final entry in ((json['secrets'] as Map?) ?? {}).entries)
          entry.key as String: entry.value as String,
      },
      seedTasks: [
        for (final task in (json['tasks'] as List? ?? const []))
          (task as Map).cast<String, dynamic>(),
      ],
      embedderMode: json['embedder'] as String?,
      registerChannels: register,
      inbound: inbound,
      ticks: ticks,
      clockNow: clock == null ? null : DateTime.parse(clock['now'] as String),
      stubs: stubs,
      api: api == null ? null : (steps: apiSteps),
      hostShellPosix: json['host_shell'] == 'posix',
      expect: _expect((json['expect'] as Map).cast<String, dynamic>()),
    );
  }

  static PilotExpect _expect(Map<String, dynamic> json) {
    final answer = (json['answer'] as Map?)?.cast<String, dynamic>();
    final files = json['files'] as Map?;
    final runs = json['runs'] as List?;
    final memory = json['memory'] as Map?;
    final embeddings = json['embeddings'] as Map?;
    final tasks = json['tasks'] as Map?;
    final fired = json['fired'] as List?;
    final channels = json['channels'] as List?;
    final scheduler = json['scheduler'] as List?;
    final api = json['api'] as List?;
    final notifications = json['notifications'] as List?;
    final logs = json['logs'] as List?;
    final policy = json['policy'] as List?;
    return PilotExpect(
      status: PilotTaskStatus.parse(json['status']),
      answerEquals: answer?['equals'] as String?,
      answerContains: answer?['contains'] as String?,
      answerNotContains: answer?['notContains'] as String?,
      files: files == null
          ? null
          : {
              for (final entry in files.entries)
                entry.key as String: entry.value as String,
            },
      tools: (json['tools'] as List?)?.cast<String>(),
      observations: (json['observations'] as List?)?.cast<String>(),
      runs: [
        for (final run in runs ?? const [])
          _runExpect((run as Map).cast<String, dynamic>()),
      ],
      plan: (json['plan'] as List?)?.cast<String>(),
      sessionPersisted: json['sessionPersisted'] as bool?,
      stdoutContains: json['stdoutContains'] as String?,
      prefixStable: json['prefixStable'] as bool?,
      memory: memory == null
          ? null
          : {
              for (final entry in memory.entries)
                entry.key as String: entry.value as String,
            },
      recall: (json['recall'] as List?)?.cast<String>(),
      embeddingsRebuilt: embeddings?['rebuilt'] as bool?,
      embeddingsModel: embeddings?['model'] as String?,
      embeddingsIds:
          (embeddings?['ids'] as List?)?.cast<String>(),
      tasks: [
        for (final entry in (tasks ?? const {}).entries)
          TaskExpect(
            goalSubstring: entry.key as String,
            status: (entry.value as Map)['status'] as String,
            nextDue: (entry.value as Map)['next_due'] as String?,
            repeat: (entry.value as Map)['repeat'] as String?,
          ),
      ],
      fired: [
        for (final fire in fired ?? const [])
          PilotFireRecord(
            task: (fire as Map)['task'] as String,
            due: DateTime.parse(fire['due'] as String),
          ),
      ],
      channels: [
        for (final channel in channels ?? const [])
          ChannelExpect(
            channel: (channel as Map)['channel'] as String?,
            to: channel['to'] as String?,
            message: channel['message'] as String?,
          ),
      ],
      scheduler: scheduler?.cast<String>() ?? const [],
      api: [
        for (final entry in api ?? const [])
          (entry as Map).cast<String, dynamic>(),
      ],
      notifications: [
        for (final notification in notifications ?? const [])
          NotificationExpect(
            title: (notification as Map)['title'] as String?,
            message: notification['message'] as String?,
          ),
      ],
      logs: [
        for (final log in logs ?? const [])
          LogExpect(
            kind: (log as Map)['kind'] as String,
            tool: log['tool'] as String?,
            detail: log['detail'] as String?,
            status: log['status'] as String?,
          ),
      ],
      policy: [
        for (final decision in policy ?? const [])
          PolicyExpect(
            event: (decision as Map)['event'] as String,
            tool: decision['tool'] as String,
            detail: decision['detail'] as String?,
          ),
      ],
      reason: json['reason'] as String?,
    );
  }

  static RunExpect _runExpect(Map<String, dynamic> json) {
    final answer = (json['answer'] as Map?)?.cast<String, dynamic>();
    return RunExpect(
      status: PilotTaskStatus.parse(json['status']),
      answerEquals: answer?['equals'] as String?,
      answerContains: answer?['contains'] as String?,
      reason: json['reason'] as String?,
    );
  }
}

/// One expected fire record (task + due), for the idempotency assertion.
final class PilotFireRecord {
  const PilotFireRecord({required this.task, required this.due});
  final String task;
  final DateTime due;
}

/// Status wire parsing shared by the Pilot task loader.
class PilotTaskStatus {
  static RunStatus? parse(Object? value) => switch (value) {
        null => null,
        'complete' => RunStatus.complete,
        'incomplete' => RunStatus.incomplete,
        'blocked' => RunStatus.blocked,
        _ => throw FormatException('bad status: $value'),
      };
}

/// Parse a `+<n><m|h|d>` tick advance; null for any other shape.
Duration? parseAdvance(String spec) {
  final match = RegExp(r'^\+(\d+)([mhd])$').firstMatch(spec);
  if (match == null) return null;
  final n = int.parse(match.group(1)!);
  return switch (match.group(2)) {
    'm' => Duration(minutes: n),
    'h' => Duration(hours: n),
    _ => Duration(days: n),
  };
}

/// A parsed scheduled-task seed (autonomy.schema.json `scheduledTask`).
/// `when` sets the first due instant: an ISO timestamp or a relative
/// `+<n><m|h|d>` resolved against the pinned clock (C11).
ScheduledTask seedTaskFromJson(Map<String, dynamic> json,
    {DateTime? now}) {
  final when = json['when'] as String?;
  final due = json['next_due'] != null
      ? DateTime.parse(json['next_due'] as String)
      : when == null
          ? null
          : resolveWhen(when, now ?? DateTime.utc(2026, 10, 6, 9));
  return ScheduledTask(
    id: json['id'] as String,
    goal: json['goal'] as String,
    when: when,
    nextDue: due,
    repeat: json['repeat'] as String?,
    channel: json['channel'] as String?,
    originChannel:
        json['origin'] is Map ? (json['origin'] as Map)['channel'] as String? : null,
    originFrom:
        json['origin'] is Map ? (json['origin'] as Map)['from'] as String? : null,
    originSession: json['origin'] is Map
        ? (json['origin'] as Map)['session'] as String?
        : null,
    status: json['status'] as String? ?? 'pending',
    created: json['created'] != null
        ? DateTime.parse(json['created'] as String)
        : DateTime.fromMillisecondsSinceEpoch(0),
    updated: json['updated'] != null
        ? DateTime.parse(json['updated'] as String)
        : DateTime.fromMillisecondsSinceEpoch(0),
    lastRun: json['last_run'] != null
        ? DateTime.parse(json['last_run'] as String)
        : null,
  );
}

/// A parsed channel registration (channel.schema.json `channel`).
ChannelConfig channelFromJson(Map<String, dynamic> json) =>
    ChannelConfig.fromJson(json);

/// The guard result of a channel admission check (C10).
final class ChannelAdmission {
  const ChannelAdmission.allowed(this.config)
      : denied = false,
        reason = null;
  const ChannelAdmission.denied(this.config, this.reason)
      : denied = true;
  final ChannelConfig config;
  final bool denied;
  final String? reason;
}
