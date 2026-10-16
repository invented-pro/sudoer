import '../models.dart';

/// The expected result of one goal run.
final class RunExpect {
  const RunExpect({this.status, this.answerEquals, this.answerContains});

  final RunStatus? status;
  final String? answerEquals;
  final String? answerContains;
}

/// The expected observable outcome of a gate task.
final class Expect {
  const Expect({
    this.status,
    this.answerEquals,
    this.answerContains,
    this.files,
    this.tools,
    this.observations,
    this.runs = const [],
    this.plan,
    this.sessionPersisted,
    this.stdoutContains,
  });

  final RunStatus? status;
  final String? answerEquals;
  final String? answerContains;
  final Map<String, String>? files;
  final List<String>? tools;

  /// Expected substrings of the tool observations, in call order: entry i
  /// must appear in the i-th observation. Shorter than the tool-call log
  /// means only the prefix is checked.
  final List<String>? observations;

  final List<RunExpect> runs;
  final List<String>? plan;
  final bool? sessionPersisted;
  final String? stdoutContains;
}

/// One input typed into the interactive session (C6).
final class Turn {
  const Turn.goal(this.goal) : command = null;
  const Turn.command(this.command) : goal = null;

  final String? goal;
  final String? command;
}

/// One gate task, mirroring `00_bp/agent_prop/task.schema.json`.
final class Task {
  const Task({
    required this.id,
    required this.turns,
    required this.workspace,
    required this.configOverride,
    required this.script,
    required this.expect,
    this.hostShellPosix = false,
  });

  final String id;
  final List<Turn> turns;
  final Map<String, String> workspace;
  final Map<String, dynamic> configOverride;
  final Map<String, dynamic> script;
  final Expect expect;

  /// True when the task's `run_command` strings assume the POSIX host shell
  /// (`host_shell: "posix"`); skipped on Windows, where the shell paths are
  /// unit-tested instead (C3).
  final bool hostShellPosix;

  factory Task.fromJson(Map<String, dynamic> json) {
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

    final expect = (json['expect'] as Map).cast<String, dynamic>();
    final answer = (expect['answer'] as Map?)?.cast<String, dynamic>();
    final files = expect['files'] as Map?;
    final runs = expect['runs'] as List?;
    return Task(
      id: json['id'] as String,
      turns: turns,
      workspace: {
        for (final entry in ((json['workspace'] as Map?) ?? {}).entries)
          entry.key as String: entry.value as String,
      },
      configOverride:
          ((json['config'] as Map?) ?? {}).cast<String, dynamic>(),
      script: (json['script'] as Map).cast<String, dynamic>(),
      hostShellPosix: json['host_shell'] == 'posix',
      expect: Expect(
        status: _status(expect['status']),
        answerEquals: answer?['equals'] as String?,
        answerContains: answer?['contains'] as String?,
        files: files == null
            ? null
            : {
                for (final entry in files.entries)
                  entry.key as String: entry.value as String,
              },
        tools: (expect['tools'] as List?)?.cast<String>(),
        observations: (expect['observations'] as List?)?.cast<String>(),
        runs: [
          for (final run in runs ?? const [])
            _runExpect((run as Map).cast<String, dynamic>()),
        ],
        plan: (expect['plan'] as List?)?.cast<String>(),
        sessionPersisted: expect['sessionPersisted'] as bool?,
        stdoutContains: expect['stdoutContains'] as String?,
      ),
    );
  }

  static RunStatus? _status(Object? value) => switch (value) {
        null => null,
        'complete' => RunStatus.complete,
        'incomplete' => RunStatus.incomplete,
        'blocked' => RunStatus.blocked,
        _ => throw FormatException('bad status: $value'),
      };

  static RunExpect _runExpect(Map<String, dynamic> json) {
    final answer = (json['answer'] as Map?)?.cast<String, dynamic>();
    return RunExpect(
      status: _status(json['status']),
      answerEquals: answer?['equals'] as String?,
      answerContains: answer?['contains'] as String?,
    );
  }
}
