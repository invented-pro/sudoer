import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'autonomy.dart';
import 'config.dart';
import 'embedder.dart';
import 'errors.dart';
import 'interface.dart';
import 'memory.dart';
import 'models.dart';
import 'pilot_agent.dart';
import 'pilot_config.dart';
import 'pilot_runtime.dart';
import 'providers/provider.dart';
import 'providers/scripted.dart';
import 'reliability.dart';
import 'scheduler.dart';
import 'session.dart';

/// The Pilot surface logic shared by the entrypoint (`bin/sudoer.dart`) and
/// the gate harness: the Pilot `/commands` (C6), the autonomy seam, and the
/// gate's scripted-provider injection. One implementation, so the harness
/// drives exactly what ships.

/// The autonomy engine over a runtime; fired goals run as system-origin
/// goals in the given session (or a fresh one for a wake `tick`) (C11).
Autonomy autonomyFor(PilotRuntime runtime, Session? session) => Autonomy(
      runtime: runtime,
      runGoal: (run) async {
        final agent = PilotAgent.assemble(
          runtime: runtime,
          session: run.session ??
              session ??
              Session.create(workspaceRoot: runtime.config.primaryRoot),
          chain: gateChain(),
          reliability: gateReliability(),
        );
        try {
          final result =
              await agent.run(RunRequest(run.goal), system: run.system);
          return result.answer;
        } finally {
          await agent.dispose();
        }
      },
    );

/// The Pilot REPL hooks: the PilotAgent assembly and the Pilot `/commands`,
/// reached through the REPL's extension seam (C6: Prop surfaces untouched).
ReplHooks pilotHooks(PilotRuntime runtime) {
  return ReplHooks(
    buildAgent: (session) => PilotAgent.assemble(
      runtime: runtime,
      session: session,
      chain: gateChain(),
      reliability: gateReliability(),
    ),
    command: (line) => handlePilotCommand(
      line,
      runtime,
      out: stdout,
      err: stderr,
    ),
    beforeGoal: (goal) {
      // C11: a run boundary is a scheduler check point, so a task that came
      // due between runs becomes the next system goal in its session.
      autonomyFor(runtime, null).tick();
    },
  );
}

/// The Pilot `/commands` (C6): /schedule, /remind, /tasks, /memory,
/// /model, /channels — each on any surface. Returns true when the line was
/// one of Pilot's; false falls through to Prop's commands.
bool handlePilotCommand(
  String line,
  PilotRuntime runtime, {
  StringSink? out,
  StringSink? err,
  Session? session,
}) {
  final sink = out ?? stdout;
  final errors = err ?? stderr;
  final parts = line.split(RegExp(r'\s+'));
  final command = parts.first;
  final rest = parts.length > 1 ? parts.sublist(1) : <String>[];
  switch (command) {
    case '/schedule':
    case '/remind':
      if (rest.length < 2) {
        errors.writeln('usage: $command <when> <goal>');
        return true;
      }
      final when = rest.first;
      final goal = rest.sublist(1).join(' ');
      final clock = runtime.clock;
      final due = resolveWhen(when, clock.now());
      if (due == null) {
        errors.writeln('cannot resolve when: $when');
        return true;
      }
      final store = TaskStore(runtime.config.tasksFile, clock);
      final tasks = store.load();
      final id = nextTaskId(tasks, goal);
      tasks.add(ScheduledTask(
        id: id,
        goal: goal,
        when: when,
        nextDue: due,
        status: 'pending',
        created: clock.now(),
        updated: clock.now(),
      ));
      store.save(tasks);
      runtime.log.emitTask(id, 'scheduled', due: due);
      sink.writeln('scheduled $id: "$goal" due ${due.toIso8601String()}');
      return true;
    case '/tasks':
      tasksCommand(runtime, rest, sink, errors);
      return true;
    case '/memory':
      memoryCommand(runtime, rest, sink);
      return true;
    case '/model':
      modelCommand(runtime, rest, sink, errors);
      return true;
    case '/channels':
      for (final channel in runtime.config.channels) {
        sink.writeln('${channel.id}\t${channel.kind ?? 'channel'}\t'
            '${channel.enabled ? 'enabled' : 'disabled'}');
      }
      if (runtime.config.channels.isEmpty) sink.writeln('no channels');
      return true;
    default:
      return false;
  }
}

/// `/tasks [cancel <id> | run <id>]` (C11): list pending tasks with ids and
/// next due times; cancel or fire one.
void tasksCommand(PilotRuntime runtime, List<String> rest, StringSink out,
    StringSink err) {
  final store = TaskStore(runtime.config.tasksFile, runtime.clock);
  if (rest.isNotEmpty && rest.first == 'cancel') {
    if (rest.length < 2) {
      err.writeln('usage: /tasks cancel <id>');
      return;
    }
    final id = rest[1];
    final ok = autonomyFor(runtime, null).cancel(id);
    out.writeln(ok ? 'cancelled $id' : 'no pending task $id');
    return;
  }
  if (rest.isNotEmpty && rest.first == 'run') {
    if (rest.length < 2) {
      err.writeln('usage: /tasks run <id>');
      return;
    }
    final id = rest[1];
    final autonomy = autonomyFor(runtime, null);
    autonomy.runNow(id).then((fired) {
      out.writeln(fired ? 'fired $id' : 'cannot fire $id');
    });
    return;
  }
  final pending = [
    for (final task in store.load())
      if (task.isActive) task,
  ];
  if (pending.isEmpty) {
    out.writeln('no pending tasks');
    return;
  }
  for (final task in pending) {
    out.writeln('${task.id}\t${task.status}\t'
        '${task.nextDue?.toIso8601String() ?? '-'}\t${task.goal}');
  }
}

/// `/memory [query | rebuild]` (C9): list or search memory notes; rebuild
/// the embedding index.
void memoryCommand(PilotRuntime runtime, List<String> rest, StringSink out) {
  final memory = memoryStore(runtime);
  if (rest.isNotEmpty && rest.first == 'rebuild') {
    final index = memory.rebuildIndex();
    out.writeln('rebuilt the embedding index: ${index.vectors.length} notes '
        '(model ${index.model})');
    return;
  }
  final query = rest.isEmpty ? null : rest.join(' ');
  if (query == null) {
    final notes = memory.all();
    if (notes.isEmpty) {
      out.writeln('memory is empty');
      return;
    }
    for (final note in notes) {
      out.writeln('${note.id}\t${note.title}');
    }
    return;
  }
  final hits = memory.search(query);
  if (hits.isEmpty) {
    out.writeln('no memory notes matched');
    return;
  }
  for (final hit in hits) {
    out.writeln(hit.line);
  }
}

/// `/model [name]` (C2): show the catalog, or switch `main` at the next
/// goal boundary.
void modelCommand(
    PilotRuntime runtime, List<String> rest, StringSink out, StringSink err) {
  final chain = runtime.config.chain;
  if (rest.isEmpty) {
    for (var i = 0; i < chain.length; i++) {
      out.writeln('$i\t${chain[i].model}${i == 0 ? '\t(primary)' : ''}');
    }
    return;
  }
  final index = int.tryParse(rest.first);
  if (index == null || index < 0 || index >= chain.length) {
    err.writeln('usage: /model <chain index 0..${chain.length - 1}>');
    return;
  }
  out.writeln('main -> ${chain[index].model} (from the next goal)');
}

/// The memory store for surface commands (the configured embedder, or the
/// bundled local default).
MemoryStore memoryStore(PilotRuntime runtime) {
  final config = runtime.config;
  // The harness's pinned embedder wins (C9/gate: deterministic memory);
  // production resolves the configured kind, defaulting to the bundled
  // local model.
  final embedder = runtime.embedder ??
      (config.embedder == null
          ? LocalEmbedder()
          : embedderFromConfig({
              'kind': config.embedder!.kind,
              'base_url': config.embedder!.baseUrl,
              'model': config.embedder!.model,
            }));
  return MemoryStore(config.memoryDir, embedder);
}

/// The slug id for a new task (the goal, slugged; disambiguated).
String nextTaskId(List<ScheduledTask> tasks, String goal) {
  var base = goal
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) base = 'task';
  base = base.substring(0, base.length.clamp(0, 32));
  if (!tasks.any((task) => task.id == base)) return base;
  var n = 2;
  while (tasks.any((task) => task.id == '$base-$n')) {
    n++;
  }
  return '$base-$n';
}

/// The Prop-shaped config view for the REPL seam (the REPL core reads its
/// own fields; Pilot's extra keys ride on the runtime).
Config propConfigOf(PilotConfig config) => Config(
      provider: config.primary,
      workspaceRoot: config.primaryRoot,
      sessionDir: config.sessionDir,
      web: config.web,
    );

/// Load the Pilot configuration from a JSON file (C6: one `sudoer.json`).
PilotConfig loadPilotConfig(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    if (path == (Platform.environment['SUDOER_CONFIG'] ?? 'sudoer.json')) {
      return defaultPilotConfig(
          p.normalize(p.absolute(Directory.current.path)));
    }
    throw ConfigNotFoundException(path);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    throw ConfigException('config is not valid JSON: ${e.message}');
  }
  if (decoded is! Map) {
    throw const ConfigException('config must be a JSON object');
  }
  return PilotConfig.fromJson(decoded.cast<String, dynamic>(),
      defaultRoot: p.normalize(p.absolute(Directory.current.path)));
}

/// The default Pilot config when no file exists: the documented default
/// shape, anchored at the working directory. Every Pilot store lands under
/// `<root>/.sudoer/` (C6/C9/C11), so a fresh machine works out of the box.
PilotConfig defaultPilotConfig(String root) => PilotConfig.fromJson({
      'provider': {
        'kind': 'ollama',
        'model': 'scripted',
        'context_window': 8192,
      },
    }, defaultRoot: root);

/// The scripted-provider seam (C2/gate): when `SUDOER_SCRIPT_FILE` is set,
/// the chain is scripted from that file — harness-injected, never
/// config-reachable.
List<Provider>? gateChain() {
  final path = Platform.environment['SUDOER_SCRIPT_FILE'];
  if (path == null) return null;
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  // One scripted chain per process (gate.md): every agent this process
  // builds continues the same cursor.
  return [ScriptedProvider.fromJson(json, sharedKey: path)];
}

/// The gate pins the backoff sleep to a no-op via the same seam.
Reliability? gateReliability() =>
    Platform.environment['SUDOER_SCRIPT_FILE'] == null
        ? null
        : const Reliability(sleep: _noSleep);

Future<void> _noSleep(Duration _) async {}
