import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent.dart';
import 'config.dart';
import 'console.dart';
import 'diagnostics.dart';
import 'errors.dart';
import 'line_editor.dart';
import 'modality.dart';
import 'models.dart';
import 'platform.dart';
import 'providers/ollama.dart';
import 'providers/openai_compatible.dart';
import 'providers/provider.dart';
import 'providers/scripted.dart';
import 'session.dart';
import 'tools/job.dart';

/// The two Prop surfaces (C6). Both are line CLIs on the normal terminal
/// scrollback: [human] adds color, italics, a spinner, streamed replies, and
/// a status line; [automate] is plain, one-shot, and pipe-friendly.
enum UiMode { human, automate }

/// Choose the surface. Human is the default; `--automate`, or a
/// non-interactive terminal, selects the plain line path so scripts never
/// hang. `--human` forces the styled path (useful when detection is wrong).
UiMode chooseMode({
  required bool automate,
  required bool human,
  required bool interactive,
}) {
  if (automate) return UiMode.automate;
  if (human) return UiMode.human;
  return interactive ? UiMode.human : UiMode.automate;
}

/// Build the provider for [config].
///
/// The `SUDOER_SCRIPT_FILE` environment variable is the gate's offline seam:
/// when set, a deterministic scripted provider is loaded from that file
/// instead of contacting a real endpoint.
Provider providerFor(ProviderConfig config) {
  final scriptPath = Platform.environment['SUDOER_SCRIPT_FILE'];
  if (scriptPath != null) {
    final json =
        jsonDecode(File(scriptPath).readAsStringSync()) as Map<String, dynamic>;
    return ScriptedProvider.fromJson(json);
  }
  return switch (config.kind) {
    ProviderKind.openAiCompatible => OpenAiCompatibleProvider(config),
    ProviderKind.ollama => OllamaProvider(config),
  };
}

/// C6: one-shot CLI. Returns a process exit code: 0 when an answer is
/// produced (including a best-effort incomplete one), non-zero when blocked.
Future<int> runCli({
  required Config config,
  required String goal,
  StringSink? out,
  StringSink? err,
  Provider Function(ProviderConfig config)? providerFactory,
  List<String>? callLog,
  bool verbose = false,
  bool human = false,
}) async {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  final factory = providerFactory ?? providerFor;
  final console = Console(out: outSink, err: errSink, ansi: human, spinner: human);
  final observer = human ? _CliObserver(console) : null;

  final agent = PropAgent.assemble(
    config: config,
    provider: factory(config.provider),
    callLog: callLog,
    diagnostics: Diagnostics(
      enabled: verbose,
      sink: human ? console.diagnostic : errSink.writeln,
    ),
  );
  try {
    if (human) {
      console.banner('Sudoer · ${providerLabel(config.provider.kind)}/'
          '${config.provider.model}');
      console.user(goal);
    }
    final result = await agent
        .run(RunRequest(normalizeToText(goal)), observer: observer);

    if (human) {
      console.stopThinking();
      console.endLine();
      if (result.status == RunStatus.blocked) {
        console.error('blocked: ${result.reason ?? 'unknown'}');
        console.status(_statusText(observer!, result, agent.session),
            kind: result.status.wire);
        return 1;
      }
      if (result.status == RunStatus.incomplete && result.answer != null) {
        console.answer(result.answer!);
      }
      console.status(_statusText(observer!, result, agent.session),
          kind: result.status.wire);
      return 0;
    }

    switch (result.status) {
      case RunStatus.blocked:
        errSink.writeln('blocked: ${result.reason ?? 'unknown'}');
        _printTimings(errSink, result);
        return 1;
      case RunStatus.incomplete:
        outSink.writeln(result.answer ?? '');
        errSink.writeln('incomplete: ${result.reason ?? 'incomplete'}');
        _printTimings(errSink, result);
        return 0;
      case RunStatus.complete:
        outSink.writeln(result.answer ?? '');
        _printTimings(errSink, result);
        return 0;
    }
  } finally {
    // Reap any background job this one-shot run started (C3/C8).
    await agent.dispose();
  }
}

/// The outcome of an interactive session (C6).
final class ReplOutcome {
  ReplOutcome({required this.exitCode, required this.runs, required this.session});
  final int exitCode;
  final List<RunResult> runs;
  final Session session;
}

/// C6: the interactive CLI. Reads lines from [input]; a line starting with
/// `/` is a command, any other line is a goal run inside the current session.
/// Answers go to [out]; diagnostics, plan, and status go to [err].
///
/// On a real terminal ([interactive] plus [rawInput]) the human surface takes
/// over the keyboard in raw mode: a [LineEditor] gives arrow-key cursor
/// movement, Up/Down history, and multi-line goals (a trailing `\` continues
/// the line), and a double `Esc` interrupts the in-flight run. Off a terminal
/// the plain line path is used unchanged.
Future<ReplOutcome> runRepl({
  required Config config,
  required Stream<String> input,
  Stream<List<int>>? rawInput,
  bool interactive = false,
  StringSink? out,
  StringSink? err,
  Provider Function(ProviderConfig config)? providerFactory,
  Session? session,
  bool verbose = false,
  bool human = false,
  bool echoInput = false,
  List<String>? callLog,
}) {
  return _Repl(
    config: config,
    console: Console(
      out: out ?? stdout,
      err: err ?? stderr,
      ansi: human,
      spinner: human,
    ),
    provider: (providerFactory ?? providerFor)(config.provider),
    session: session ?? Session.create(workspaceRoot: config.workspaceRoot),
    verbose: verbose,
    human: human,
    interactive: interactive,
    echoInput: echoInput,
    callLog: callLog,
  ).start(input: input, rawInput: rawInput);
}

/// The mutable REPL state shared by the piped line path and the interactive
/// raw-keyboard path: the session, the assembled agent, and the command
/// dispatch. Keeping it in one place means both surfaces behave identically.
final class _Repl {
  _Repl({
    required this.config,
    required this.console,
    required this.provider,
    required this.session,
    required this.verbose,
    required this.human,
    required this.interactive,
    required this.echoInput,
    this.callLog,
  }) {
    workspaceRoot = session.workspaceRoot;
    diagnostics = Diagnostics(
      enabled: verbose,
      sink: human ? console.diagnostic : console.err.writeln,
    );
    agent = _build();
  }

  final Config config;
  final Console console;
  final Provider provider;
  final bool verbose;
  final bool human;
  final bool interactive;
  final bool echoInput;
  final List<String>? callLog;

  final List<RunResult> runs = [];
  late final Diagnostics diagnostics;

  /// Background jobs shared across agent rebuilds (a workspace change must
  /// not orphan a running dev server); reaped when the session closes (C8).
  final JobRegistry jobs = JobRegistry();

  Session session;
  late String workspaceRoot;
  late PropAgent agent;
  int exitCode = 0;

  /// Resolves the pending `[y/N]` outside-workspace authorization, if any.
  Completer<bool>? _authCompleter;

  PropAgent _build() => PropAgent.assemble(
        config: config.copyWith(workspaceRoot: workspaceRoot),
        provider: provider,
        session: session,
        callLog: callLog,
        diagnostics: diagnostics,
        authorize: _authorize,
        jobs: jobs,
      );

  /// C6/C8: ask the human to allow a guard denial for the rest of the session.
  /// Off an interactive terminal this denies, so automation never blocks on a
  /// prompt.
  Future<bool> _authorize(String tool, String reason) {
    if (!human || !interactive) return Future.value(false);
    final pending = _authCompleter;
    if (pending != null) return pending.future;
    final completer = Completer<bool>();
    _authCompleter = completer;
    console.authorizePrompt(
        '$tool needs to reach outside the workspace ($reason).\n'
        'Allow outside-workspace access for this session?');
    return completer.future;
  }

  /// Consume a key while an authorization prompt is open. Returns true when
  /// the key was consumed (also true for keys that do not answer it).
  bool _handleAuthKey(Key key) {
    final completer = _authCompleter;
    if (completer == null) return false;
    bool? answer;
    if (key.kind == KeyKind.rune) {
      final ch = String.fromCharCode(key.rune).toLowerCase();
      if (ch == 'y') answer = true;
      if (ch == 'n') answer = false;
    } else if (key.kind == KeyKind.enter || key.kind == KeyKind.esc) {
      answer = false;
    }
    if (answer == null) return true;
    _authCompleter = null;
    console.authorizeResult(answer);
    if (!completer.isCompleted) completer.complete(answer);
    return true;
  }

  Future<ReplOutcome> start({
    required Stream<String> input,
    Stream<List<int>>? rawInput,
  }) {
    if (human) {
      console.banner('Sudoer · ${providerLabel(config.provider.kind)}/'
          '${config.provider.model}');
      console.header('workspace $workspaceRoot');
      console.header('Type a goal, or /help. Ctrl+C to quit.');
    }
    if (human && interactive && rawInput != null) {
      return _interactive(rawInput);
    }
    return _stream(input);
  }

  /// The piped / non-terminal path: one line per turn.
  ///
  /// Input is read *concurrently* with each run so a `/cancel` line can arrive
  /// mid-run and abort it (C6, C8). Every other line is buffered and handled in
  /// order after the current run completes, so command dispatch and goal order
  /// are unchanged.
  Future<ReplOutcome> _stream(Stream<String> input) async {
    if (human) console.prompt();
    final queue = <String>[];
    var inputDone = false;
    var running = false;
    Completer<void>? wake;

    void notify() {
      final pending = wake;
      wake = null;
      if (pending != null && !pending.isCompleted) pending.complete();
    }

    Future<void> waitForWork() {
      if (queue.isNotEmpty || inputDone) return Future.value();
      final pending = Completer<void>();
      wake = pending;
      return pending.future;
    }

    final subscription = input.listen((raw) {
      // A cancel is never buffered: while a run is in flight it reaches that
      // run at once. Sent while idle it is a no-op, so a buffered `/cancel`
      // cannot leak into the next goal.
      if (_isCancel(raw)) {
        if (running) session.cancel.cancel();
        return;
      }
      queue.add(raw);
      notify();
    }, onDone: () {
      inputDone = true;
      notify();
    });

    while (!inputDone || queue.isNotEmpty) {
      if (queue.isEmpty) {
        await waitForWork();
        continue;
      }
      final line = queue.removeAt(0).trim();
      if (line.isEmpty) {
        if (human) console.prompt();
        continue;
      }
      if (line.startsWith('/')) {
        if (_isCompact(line)) {
          running = true;
          await _compact();
          running = false;
        } else if (!_command(line)) {
          break;
        }
      } else {
        if (human && echoInput) console.user(line);
        running = true;
        await _runGoal(line);
        running = false;
      }
      if (human) console.prompt();
    }
    await subscription.cancel();
    // The session is closing: reap every background job (C3/C8).
    await jobs.reapAll();
    console.close();
    return ReplOutcome(exitCode: exitCode, runs: runs, session: session);
  }

  /// The interactive path: raw keys, line editing, history, multi-line, and
  /// a double-`Esc` interrupt while a run is in flight.
  Future<ReplOutcome> _interactive(Stream<List<int>> rawInput) async {
    final reader = KeyReader(rawInput);
    final editor = LineEditor(
      write: console.out.write,
      stylePrompt: (prompt) => console.style(prompt, bold: true),
    );
    final finished = Completer<void>();
    final doubleEsc = DoubleEsc();
    var running = false;
    var shellRunning = false;
    var stopped = false;
    var cancelled = false;

    final subscription = reader.keys.listen((key) {
      if (stopped) return;
      if (_handleAuthKey(key)) return;
      if (running) {
        if (key.kind != KeyKind.esc) return;
        // A direct shell command (`!`) is not interruptible: swallow Esc so
        // the hint never promises a cancel it cannot deliver.
        if (shellRunning) return;
        if (!cancelled && doubleEsc.press()) {
          cancelled = true;
          session.cancel.cancel();
          console.setHint('interrupting…');
        } else if (!cancelled) {
          console.setHint('Esc again to interrupt');
        }
        return;
      }
      final result = editor.handle(key);
      switch (result.kind) {
        case EditKind.submit:
          editor.finish();
          final line = result.text.trim();
          if (line.isEmpty) {
            editor.begin();
            } else if (line.startsWith('!')) {
              // C6: a `!` line runs directly as a shell command; the model is
              // never involved. Human CLI only.
              running = true;
              shellRunning = true;
              console.setHint(null);
              _shell(line.substring(1).trim()).whenComplete(() {
                running = false;
                shellRunning = false;
                if (stopped) return;
                console.endLine();
                editor.begin();
              });
            } else if (line.startsWith('/')) {
              if (_isCompact(line)) {
                running = true;
                console.setHint(null);
                _compact().whenComplete(() {
                  running = false;
                  if (stopped) return;
                  console.endLine();
                  editor.begin();
                });
              } else if (_command(line)) {
                editor.begin();
              } else {
                stopped = true;
                if (!finished.isCompleted) finished.complete();
              }
            } else {
            final embedded = embeddedCommand(result.text);
            if (embedded != null) {
              console.endLine();
              console.info("note: '$embedded' is on a continuation line, so "
                  'this is a multi-line goal, not a command (commands must be '
                  'one line)');
            }
            running = true;
            cancelled = false;
            doubleEsc.reset();
            console.setHint('press Esc twice to interrupt');
            _runGoal(result.text).whenComplete(() {
              running = false;
              console.setHint(null);
              if (stopped) return;
              console.endLine();
              editor.begin();
            });
          }
        case EditKind.eof:
          stopped = true;
          if (!finished.isCompleted) finished.complete();
        case EditKind.pending:
          break;
      }
    }, onDone: () {
      final auth = _authCompleter;
      if (auth != null && !auth.isCompleted) {
        _authCompleter = null;
        auth.complete(false);
      }
      if (!finished.isCompleted) finished.complete();
    });

    editor.begin();
    await finished.future;
    stopped = true;
    await subscription.cancel();
    await reader.close();
    // The session is closing: reap every background job (C3/C8).
    await jobs.reapAll();
    console.close();
    return ReplOutcome(exitCode: exitCode, runs: runs, session: session);
  }

  /// C4/C6: fold older context into a brief on demand (`/compact`), below the
  /// automatic watermark. Shared by both surfaces.
  Future<void> _compact() async {
    if (human) console.startThinking('compacting context');
    final info = await agent.compact();
    if (human) {
      console.stopThinking();
      console.endLine();
    }
    if (info == null) {
      console.info('nothing to compact');
    } else {
      console.info('↺ compacted ${info.steps} earlier steps '
          '(${_compactCount(info.beforeTokens)} → '
          '${_compactCount(info.afterTokens)} tokens)');
    }
  }

  /// C6: run a `!` line directly as a shell command in the workspace root,
  /// forwarding its stdout and stderr untouched. The model is not involved.
  /// Human CLI only.
  Future<void> _shell(String command) async {
    console.endLine();
    try {
      final code = await runShellCommand(
        command: command,
        workingDirectory: p.normalize(p.absolute(workspaceRoot)),
        out: console.out,
        err: console.err,
      );
      if (code != 0) console.error('exit $code');
    } on ProcessException catch (e) {
      console.error('cannot run command: ${e.message}');
    }
  }

  /// Run one goal and render its result. Shared by both surfaces.
  Future<RunResult> _runGoal(String goal) async {
    final observer = human ? _CliObserver(console) : null;
    final result =
        await agent.run(RunRequest(normalizeToText(goal)), observer: observer);
    runs.add(result);
    if (human) {
      console.stopThinking();
      console.endLine();
      if (result.reason == 'cancelled') {
        // A cancelled run ends at once (C6/C8); report the interrupt rather
        // than the loop's placeholder answer.
        console.info('⊘ interrupted');
      } else if (result.status == RunStatus.blocked) {
        console.error('blocked: ${result.reason ?? 'unknown'}');
      } else if (result.status == RunStatus.incomplete &&
          result.answer != null) {
        console.answer(result.answer!);
      }
      console.status(_statusText(observer!, result, session), kind: result.status.wire);
    } else {
      _render(console.out, console.err, result);
    }
    return result;
  }

  List<String> get _helpLines => helpLines(interactive: interactive);

  /// Handle a `/command`. Returns false when the REPL should exit.
  bool _command(String line) {
    final parts = line.split(RegExp(r'\s+'));
    final command = parts.first;
    final argument = parts.length > 1 ? parts[1] : null;
    switch (command) {
      case '/help':
        for (final help in _helpLines) {
          console.info(help);
        }
      case '/exit':
      case '/quit':
        return false;
      case '/new':
        session = Session.create(workspaceRoot: workspaceRoot);
        agent = _build();
        console.info('new session ${session.id}');
      case '/sessions':
        final ids = Session.list(config.sessionDir);
        console.info(ids.isEmpty ? 'no sessions' : ids.join('\n'));
      case '/resume':
        if (argument == null) {
          console.error('usage: /resume <id>');
        } else {
          try {
            session = Session.load(config.sessionDir, argument);
            agent = _build();
            console.info('resumed ${session.id}');
          } on Object catch (e) {
            console.error('cannot resume: $e');
          }
        }
      case '/plan':
        if (session.plan.isEmpty) {
          console.info('(no plan)');
        } else {
          for (final item in session.plan) {
            console.info('- [${item.done ? 'x' : ' '}] ${item.text}');
          }
        }
      case '/diff':
        // C6/C3: the workspace's changes against the session baseline.
        final argument =
            parts.length > 1 ? line.substring(command.length).trim() : null;
        if (argument != null && argument.isEmpty) {
          console.error('usage: /diff [path]');
        } else {
          try {
            console.info(agent.workspaceDiff(path: argument));
          } on GuardDeniedException catch (e) {
            console.error(e.message);
          }
        }
      case '/status':
        final last = runs.isEmpty ? null : runs.last;
        console.info('session ${session.id}: '
            '${session.transcript.length} entries, '
            '${session.plan.length} plan items, '
            'last run ${last?.status.wire ?? 'none'}');
      case '/workspace':
        if (argument == null) {
          console.info(workspaceRoot);
        } else {
          final resolved = p.normalize(p.absolute(argument));
          if (!Directory(resolved).existsSync()) {
            console.error('no such directory: $resolved');
          } else {
            workspaceRoot = resolved;
            session.workspaceRoot = resolved;
            agent = _build();
            diagnostics.event('C3 tools', 'workspace -> $resolved');
            console.info('workspace $resolved');
          }
        }
      case '/verbose':
        diagnostics.enabled = argument == 'on';
        console.info('verbose ${diagnostics.enabled ? 'on' : 'off'}');
      default:
        console.error('unknown command: $command (try /help)');
    }
    return true;
  }
}

void _render(StringSink out, StringSink err, RunResult result) {
  if (result.reason == 'cancelled') {
    // A cancelled automate run has no answer to emit; keep stdout clean.
    err.writeln('cancelled');
    _printTimings(err, result);
    return;
  }
  switch (result.status) {
    case RunStatus.complete:
      out.writeln(result.answer ?? '');
    case RunStatus.incomplete:
      out.writeln(result.answer ?? '');
      err.writeln('incomplete: ${result.reason ?? 'incomplete'}');
    case RunStatus.blocked:
      err.writeln('blocked: ${result.reason ?? 'unknown'}');
  }
  _printTimings(err, result);
}

/// Turn the loop's live signals into inline terminal output (C6).
final class _CliObserver implements RunObserver {
  _CliObserver(this.console);
  final Console console;
  int step = 0;
  int stalls = 0;
  int stallBudget = 0;
  int used = 0;
  int window = 0;
  String? _lastTool;
  Duration? _responseElapsed;

  @override
  void onDelta(String text) => console.delta(text);

  @override
  void onReasoning(String text) => console.reasoning(text);

  @override
  void onResponse(Duration elapsed) => _responseElapsed = elapsed;

  @override
  void onStep(int step, int stalls, int stallBudget) {
    this.step = step;
    this.stalls = stalls;
    this.stallBudget = stallBudget;
    // Keep the phase word alone so the elapsed time reads right after it; the
    // step/budget rides behind the timer as the spinner detail.
    console.updateThinking('thinking');
    console.setDetail(stalls > 0
        ? 'step $step · stalled $stalls/$stallBudget'
        : 'step $step');
  }

  @override
  void onContext(int used, int window) {
    this.used = used;
    this.window = window;
    console.updateThinking('thinking');
    console.setDetail('ctx ${_compactCount(used)}/${_compactCount(window)}');
  }

  @override
  void onCompaction(int steps, int beforeTokens, int afterTokens) {
    console.endLine();
    console.info('↺ compacted $steps earlier steps into a summary '
        '(${_compactCount(beforeTokens)} → ${_compactCount(afterTokens)} tokens)');
  }

  @override
  void onTool(String name, Map<String, dynamic> arguments) {
    console.stopThinking();
    _lastTool = name;
    // The response time we just measured is the latency that produced this
    // call, so it rides on the `→` line rather than a line of its own.
    console.tool(name, arguments, elapsed: _responseElapsed);
    _responseElapsed = null;
    // Keep a spinner alive while the tool runs. A `run_command` can take
    // minutes; without this the status line goes blank right after `→`.
    console.startThinking(
        name == 'run_command' ? 'running command' : 'running $name');
  }

  @override
  void onObservation(Outcome outcome, String text, {Duration? elapsed}) {
    console.stopThinking();
    console.observation(outcome, text, label: _lastTool, elapsed: elapsed);
  }

  @override
  void onPhase(String phase) {
    switch (phase) {
      case 'thinking':
        console.startThinking('thinking');
      case 'compacting':
        console.startThinking('compacting context');
      case 'acting':
        console.updateThinking('acting');
        console.setDetail(null);
      default:
        console.stopThinking();
    }
  }
}

String _statusText(_CliObserver o, RunResult result, Session session) {
  final done = session.plan.where((item) => item.done).length;
  final bar = contextBar(o.used, o.window, 12);
  // The response number within this session: one per goal run, carried across
  // a resume because the transcript is.
  final response = session.transcript.whereType<UserEntry>().length;
  final stall =
      o.stalls > 0 ? ' (stalled ${o.stalls}/${o.stallBudget})' : '';
  // The leading token is the run total, which replaces the status word; the
  // status still drives the line's colour. Fall back to the status word when
  // no timing was recorded.
  final total = _runTotal(result);
  final head = total == null ? result.status.wire : formatDuration(total);
  return '$head #$response · '
      'ctx ${_compactCount(o.used)}/${_compactCount(o.window)}'
      '${_percent(o.used, o.window)} $bar · '
      'plan $done/${session.plan.length} · step ${o.step}$stall · '
      '${shortPath(session.workspaceRoot, 40)}';
}

/// The measured total for [result], when timing was recorded.
Duration? _runTotal(RunResult result) {
  for (final timing in result.timings) {
    if (timing.label == 'run') return timing.duration;
  }
  return null;
}

/// Print a run's measured spans as plain `timing:` lines on stderr, leaving
/// stdout untouched for the automate surface.
void _printTimings(StringSink err, RunResult result) {
  for (final timing in result.timings) {
    err.writeln('timing: ${timing.label} ${formatDuration(timing.duration)}');
  }
}

/// The context use as ` (NN%)`, or empty when the window is unknown.
String _percent(int used, int window) {
  if (window <= 0) return '';
  final pct = used / window * 100;
  return ' (${pct.toStringAsFixed(pct < 10 ? 1 : 0)}%)';
}

/// A token count in K/M units, e.g. `421`, `8.2K`, `128K`, `1M`.
String _compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${_trimZero(n / 1000)}K';
  return '${_trimZero(n / 1000000)}M';
}

String _trimZero(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// The local `/` commands the REPL understands.
const Set<String> kReplCommands = {
  '/help',
  '/exit',
  '/quit',
  '/new',
  '/sessions',
  '/resume',
  '/plan',
  '/status',
  '/compact',
  '/diff',
  '/workspace',
  '/verbose',
};

/// The `/help` lines for a surface. `/cancel` is a command on the automate
/// surface only; the human CLI interrupts with a double `Esc`, so it is not
/// listed there.
List<String> helpLines({required bool interactive}) => [
      'Commands:',
      '  /help            show this help',
      '  /exit, /quit     persist and close the session, then exit',
      '  /new             start a new session',
      '  /sessions        list saved sessions',
      '  /resume <id>     switch to a saved session',
      '  /plan            print the current plan',
      '  /status          print the session status',
      '  /diff [path]     show workspace changes against the session baseline',
      if (!interactive) '  /cancel          cancel the in-flight run',
      '  /compact         fold earlier context into a brief now',
      '  /workspace [dir] print or change the workspace root',
      '  /verbose on|off  emit per-step routing on stderr',
      if (interactive)
        '  !<command>       run a shell command here (not sent to the model)',
      'Anything else is a goal for the agent.',
      if (interactive)
        '  (end a line with \\ to continue the goal on the next line)',
    ];

/// True when [line] invokes the on-demand compaction command.
bool _isCompact(String line) =>
    line.split(RegExp(r'\s+')).first == '/compact';

/// True when [line] is the cancel command. Intercepted on the piped surface
/// before buffering so it can interrupt an in-flight run (C6).
bool _isCancel(String line) =>
    line.split(RegExp(r'\s+')).first == '/cancel';

/// C6: run a `!` command directly through the host shell (C3) in
/// [workingDirectory], forwarding its stdout and stderr verbatim. Returns the
/// exit code. The model is not involved; this is the human CLI's direct shell
/// escape. It is not interruptible, so it is not tied to the cancel signal.
Future<int> runShellCommand({
  required String command,
  required String workingDirectory,
  required StringSink out,
  required StringSink err,
}) async {
  final (process, _) = await HostShell.host.start(command, workingDirectory);
  var outEndsNl = true;
  var errEndsNl = true;
  final outDone = process.stdout.transform(utf8.decoder).listen((chunk) {
    out.write(chunk);
    outEndsNl = chunk.isEmpty || chunk.endsWith('\n');
  }).asFuture<void>();
  final errDone = process.stderr.transform(utf8.decoder).listen((chunk) {
    err.write(chunk);
    errEndsNl = chunk.isEmpty || chunk.endsWith('\n');
  }).asFuture<void>();
  final code = await process.exitCode;
  await Future.wait([outDone, errDone]);
  if (!outEndsNl) out.write('\n');
  if (!errEndsNl) err.write('\n');
  return code;
}

/// A known command sitting on a continuation line of a multi-line goal. Used
/// to warn that it is goal text, not a command: only a line that *starts* a
/// submission is a command.
String? embeddedCommand(String text) {
  final lines = text.split('\n');
  if (lines.length < 2) return null;
  for (final line in lines.skip(1)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('/')) continue;
    final token = trimmed.split(RegExp(r'\s+')).first;
    if (kReplCommands.contains(token)) return token;
  }
  return null;
}

/// Convenience for callers that only have a goal + config path.
Future<int> runCliFromFile({
  required String configPath,
  required String goal,
  StringSink? out,
  StringSink? err,
}) async {
  final Config config;
  try {
    config = loadConfigFile(configPath);
  } on ConfigNotFoundException catch (e) {
    (err ?? stderr).write(missingConfigReport(e.path));
    return 2;
  } on ConfigException catch (e) {
    (err ?? stderr).writeln('config error: ${e.message}');
    return 2;
  }
  return runCli(config: config, goal: goal, out: out, err: err);
}
