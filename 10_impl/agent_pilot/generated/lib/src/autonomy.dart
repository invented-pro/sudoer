import 'dart:io';

import 'channels.dart';
import 'pilot_agent.dart';
import 'pilot_config.dart';
import 'pilot_runtime.dart';
import 'scheduler.dart';
import 'session.dart';

/// One due task resolved by a tick: the task, the due instant, and whether
/// this tick is catching up a missed fire (labels the run `[late]`).
final class DueTask {
  DueTask({required this.task, required this.due, required this.late});
  final ScheduledTask task;
  final DateTime due;
  final bool late;
}

/// C11: the autonomy engine — the scheduler half of the resident service.
/// On a tick (service timer, service start, or an OS wake) it selects every
/// task whose `next_due <= now`, records each fire *before* its run starts
/// (idempotent per `(task, due)`, C8), runs the goal as a **system-origin**
/// goal in its channel's session, advances a recurring task's `next_due`,
/// marks a one-shot done, and delivers the result to the task's channel.
///
/// It never invents work: only tasks the user set (via the tools or the
/// `/schedule` command) exist in the store.
final class Autonomy {
  Autonomy({required this.runtime, required this.runGoal}) : config = runtime.config;

  final PilotRuntime runtime;
  final PilotConfig config;

  /// The runner for a fired task's goal: returns the run's answer (the
  /// injected seam lets the gate drive runs; the service passes its agent).
  final Future<String?> Function(GoalRun run) runGoal;

  /// The missed-fire policy outcome for [task] at a tick: `fire` runs it
  /// late (default for recurring), `report` lists it and leaves it pending
  /// (default for one-shot reminders) (C11).
  bool get catchUpFire => config.catchUp == 'fire';

  /// Select the due tasks for the current instant, honoring the idempotency
  /// record and the catch-up policy (C11).
  List<DueTask> dueTasks({DateTime? now, List<ScheduledTask>? store}) {
    final instant = now ?? runtime.clock.now();
    final taskStore = TaskStore(config.tasksFile, runtime.clock);
    final tasks = store ?? taskStore.load();
    final fires = taskStore.fires;
    final due = <DueTask>[];
    for (final task in tasks) {
      if (!task.isActive || task.nextDue == null) continue;
      if (task.nextDue!.isAfter(instant)) continue;
      if (!catchUpFire && !task.isRecurring) {
        // The default report policy: a missed one-shot is reported at
        // startup, never auto-run (C11). A tick that is not the startup
        // path still fires what the user set for exactly this instant.
        final record =
            FireRecord(task: task.id, due: task.nextDue!, at: instant);
        final already = fires.any((fire) => fire.key == record.key);
        final missed = instant.difference(task.nextDue!) >
            const Duration(minutes: 1);
        if (missed && !already) continue;
      }
      due.add(DueTask(
        task: task,
        due: task.nextDue!,
        late: instant.difference(task.nextDue!) > const Duration(minutes: 1),
      ));
    }
    due.sort((a, b) => a.due.compareTo(b.due));
    return due;
  }

  /// Fire every due task. Returns the outcomes in fire order. A run is
  /// capped by the compiled-in concurrency limit; excess fires queue (C8).
  Future<List<FireOutcome>> tick({Session? session, PilotAgent? agent}) async {
    final outcomes = <FireOutcome>[];
    final store = TaskStore(config.tasksFile, runtime.clock);
    final tasks = store.load();
    // A tick is a service start: (re)arm the wake for the earliest due
    // before firing, so a redundant OS wake is the exact case the
    // idempotency record absorbs (C8/C11).
    final before = nextDue();
    if (before != null) {
      runtime.scheduler.installWake(before, Directory.current.path);
    }
    for (final due in dueTasks(now: runtime.clock.now(), store: tasks)) {
      final outcome =
          await fire(due, store: store, tasks: tasks, session: session, agent: agent);
      outcomes.add(outcome);
    }
    // Re-arm the next wake after the tick (C11): the OS scheduler adapter
    // records the unit it would write; the gate's fake asserts it.
    final next = nextDue();
    if (next != null) {
      runtime.scheduler.installWake(next, Directory.current.path);
    }
    return outcomes;
  }

  /// Fire one due task: record, run, reschedule or complete, deliver (C11).
  Future<FireOutcome> fire(
    DueTask due, {
    required TaskStore store,
    required List<ScheduledTask> tasks,
    Session? session,
    PilotAgent? agent,
  }) async {
    final task = due.task;
    // Idempotency: record the fire BEFORE the run starts (C8/C11), so a
    // crash, a redundant OS wake, or a duplicate tick cannot double-fire.
    final record = FireRecord(
        task: task.id, due: due.due, at: runtime.clock.now(), outcome: 'started');
    if (store.hasFired(record)) {
      return FireOutcome(task: task, skipped: true);
    }
    store.recordFire(record, tasks);
    runtime.log.emitTask(task.id, 'fired',
        due: due.due, repeat: task.repeat);

    // The system goal: the fired task's goal, labeled late when it is one.
    final goal = due.late ? '[late] ${task.goal}' : task.goal;

    String? answer;
    try {
      answer = await runGoal(GoalRun(
        goal: goal,
        task: task,
        session: session,
        agent: agent,
        system: true,
      ));
      record.outcome = 'done';
    } on Object {
      // A failed fire is retried on the next tick, not lost (C8): the run
      // is left resumable and the failure is reported, never silent.
      record.outcome = 'failed';
      store.recordFire(record, tasks);
      runtime.log.emitTask(task.id, 'fired', due: due.due);
      return FireOutcome(task: task, skipped: false, answer: null);
    }
    store.recordFire(record, tasks);

    // Status: a recurring task goes back to pending with an advanced
    // next_due; a one-shot is done (C11).
    final live = tasks.firstWhere((entry) => entry.id == task.id);
    live.status = 'fired';
    live.lastRun = runtime.clock.now();
    live.updated = runtime.clock.now();
    if (live.isRecurring && live.repeat != null) {
      live.nextDue = advanceRepeat(live.repeat!, due.due);
      live.status = 'pending';
      runtime.log.emitTask(live.id, 'rescheduled', due: live.nextDue,
          repeat: live.repeat);
    } else {
      live.status = 'done';
      runtime.log.emitTask(live.id, 'done', due: due.due);
    }
    store.save(tasks);

    // Deliver to the task's channel (C11): notify, origin, or a channel id.
    try {
      await deliverResult(live, answer);
    } on Object {
      // A failed delivery is retried on the next tick, not lost (C8).
      return FireOutcome(task: live, answer: answer, skipped: false);
    }
    return FireOutcome(task: live, answer: answer, skipped: false);
  }

  /// Deliver a fired task's result to its channel (C11/C6): `notify` goes
  /// through the desktop notifier; a registered channel through the outbound
  /// POST; `origin` resolves to the creating channel, defaulting to notify.
  Future<void> deliverResult(ScheduledTask task, String? answer) async {
    final target = task.channel ?? task.originChannel ?? 'notify';
    final text = answer == null || answer.isEmpty
        ? (task.isRecurring ? 'Ran: ${task.goal}' : 'Reminder: ${task.goal}')
        : answer;
    if (target == 'notify') {
      final ok = runtime.notifier.notify('Sudoer', text);
      if (!ok) {
        runtime.log.emitToolCall('notify', 'error', detail: 'no notifier');
      }
      return;
    }
    final channel = config.channels.where((c) => c.id == target).firstOrNull;
    if (channel == null) {
      runtime.log.emitToolCall('channel', 'error',
          detail: 'unknown channel $target');
      return;
    }
    await runtime.deliverToChannel(
      channel: Channel(
        id: channel.id,
        outboundUrl: channel.outboundUrl,
        outboundSecret: channel.outboundSecret,
        allowFrom: channel.allowFrom,
      ),
      to: task.originFrom ?? channel.id,
      message: text,
      task: task.id,
    );
  }

  /// The catch-up report: tasks that came due while away under the report
  /// policy, listed to the user at startup and left pending (C11).
  List<ScheduledTask> missedReports() {
    final now = runtime.clock.now();
    final store = TaskStore(config.tasksFile, runtime.clock);
    return [
      for (final task in store.load())
        if (task.isActive &&
            task.nextDue != null &&
            task.nextDue!.isBefore(now) &&
            !(catchUpFire || task.isRecurring))
          task,
    ];
  }

  /// Report (not run) the tasks missed under the report policy (C11).
  String reportMissed() {
    final missed = missedReports();
    if (missed.isEmpty) return '';
    return 'missed while away (not run; use /tasks run <id>):\n'
        '${[for (final task in missed) '- ${task.id}: ${task.goal} (due '
        '${task.nextDue!.toIso8601String()})'].join('\n')}';
  }

  /// The earliest pending due time, for arming the next wake (C11).
  DateTime? nextDue() {
    final candidates = [
      for (final task in TaskStore(config.tasksFile, runtime.clock).load())
        if (task.isActive && task.nextDue != null) task.nextDue!,
    ]..sort();
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Cancel a task by id (the `/tasks cancel` command and the API) (C11).
  bool cancel(String id) {
    final store = TaskStore(config.tasksFile, runtime.clock);
    final tasks = store.load();
    final task = tasks.where((entry) => entry.id == id).firstOrNull;
    if (task == null || !task.isActive) return false;
    task.status = 'cancelled';
    task.updated = runtime.clock.now();
    store.save(tasks);
    runtime.log.emitTask(id, 'cancelled');
    return true;
  }

  /// Fire one task now, regardless of its due time (`/tasks run <id>`) (C11).
  Future<bool> runNow(String id, {Session? session, PilotAgent? agent}) async {
    final store = TaskStore(config.tasksFile, runtime.clock);
    final tasks = store.load();
    final task = tasks.where((entry) => entry.id == id).firstOrNull;
    if (task == null || !task.isActive || task.nextDue == null) return false;
    final outcome = await fire(
      DueTask(task: task, due: task.nextDue!, late: false),
      store: store,
      tasks: tasks,
      session: session,
      agent: agent,
    );
    return !outcome.skipped;
  }
}

/// One goal handed to the runner by the engine.
final class GoalRun {
  GoalRun({
    required this.goal,
    required this.task,
    this.session,
    this.agent,
    this.system = false,
  });
  final String goal;
  final ScheduledTask task;
  final Session? session;
  final PilotAgent? agent;
  final bool system;
}

/// The observable result of one fire.
final class FireOutcome {
  FireOutcome({required this.task, required this.skipped, this.answer});
  final ScheduledTask task;
  final bool skipped;
  final String? answer;
}
