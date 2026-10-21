import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart'
    show
        Cmd,
        KeyCode,
        KeyMod,
        KeyPressMsg,
        Model,
        Mouse,
        MouseButton,
        MouseClickMsg,
        MouseMode,
        MouseMotionMsg,
        MouseReleaseMsg,
        MouseWheelMsg,
        Msg,
        PasteMsg,
        Program,
        QuitMsg,
        RgbColor,
        Style,
        TeaKey,
        TextAreaModel,
        TextAreaStyles,
        View,
        WindowSizeMsg,
        withAltScreen,
        withInput;
import 'package:path/path.dart' as p;

import 'agent.dart';
import 'build_info.dart';
import 'config.dart';
import 'console.dart';
import 'diagnostics.dart';
import 'errors.dart';
import 'line_editor.dart';
import 'modality.dart';
import 'models.dart';
import 'platform.dart';
import 'providers/auth.dart';
import 'providers/discovery.dart' show presetForConfig;
import 'providers/ollama.dart';
import 'providers/openai_compatible.dart';
import 'providers/provider.dart';
import 'providers/scripted.dart';
import 'providers/setup.dart'
    show
        formatContextWindow,
        modelListText,
        providerListText,
        providerPopupItems,
        shouldPromptForKey;
import 'reliability.dart';
import 'session.dart';
import 'tools/job.dart';
import 'tui_console.dart';
import 'tui_popup.dart';

part 'tui_app.dart';

/// The two Prop surfaces (C6). [human] is the full-screen terminal app by
/// default (transcript, editor, status); `--inline` keeps the older styled
/// scrollback surface. [automate] is plain, one-shot, and pipe-friendly.
enum UiMode { human, automate }

/// Choose the surface. Human is the default; `--automate`, or a
/// non-interactive terminal, selects the plain line path so scripts never
/// hang. `--human` forces the styled path (useful when detection is wrong);
/// whether it takes the full screen is a separate `--inline` choice.
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
  // C2: resolve the key with the documented precedence (config, auth store,
  // api_key_env, well-known env var) so the adapters only ever see a value.
  final key = resolveApiKey(config);
  final effective = key == null ? config : config.copyWith(apiKey: key);
  return switch (effective.kind) {
    ProviderKind.openAiCompatible => OpenAiCompatibleProvider(effective),
    ProviderKind.ollama => OllamaProvider(effective),
  };
}

/// C6: one-shot CLI. Returns a process exit code: 0 only when the run is
/// `complete`; non-zero when it is `incomplete` (a stalled or ceiling-hit run
/// that still produced a best-effort answer) or `blocked`.
Future<int> runCli({
  required Config config,
  required String goal,
  StringSink? out,
  StringSink? err,
  Provider Function(ProviderConfig config)? providerFactory,
  List<String>? callLog,
  bool verbose = false,
  bool human = false,
  Session? session,
  Reliability? reliability,
}) async {
  final outSink = out ?? stdout;
  // Automate surface: stderr is the log, so every line written there is
  // timestamped; the human surface's stderr stays unstamped (C6).
  final errSink = human ? (err ?? stderr) : StampingSink(err ?? stderr);
  final factory = providerFactory ?? providerFor;
  final console = Console(
    out: outSink,
    err: errSink,
    ansi: human,
    spinner: human,
  );
  final observer = human ? _CliObserver(console) : null;

  // C7: strip `@path` tokens and load the images they name (C6).
  final parsed = tryParseGoal(goal);
  if (parsed == null) {
    errSink.writeln('goal error: ${goalErrorMessage(goal)}');
    return 2;
  }

  final provider = factory(config.provider);
  final agent = PropAgent.assemble(
    config: config,
    provider: provider,
    callLog: callLog,
    session: session,
    reliability: reliability,
    diagnostics: Diagnostics(
      enabled: verbose,
      sink: human ? console.diagnostic : errSink.writeln,
      // The automate log records the full LLM traffic; the human surface
      // keeps diagnostics to brief routing even with --verbose.
      traceContent: !human,
    ),
  );
  try {
    if (human) {
      // The greeting: version first, then the repo link (C6, build identity).
      console.banner('Sudoer $kBuildLabel');
      console.header(kRepoUrl);
      console.header(config.provider.display);
      console.user(goal);
    }
    final result = await agent.run(
      RunRequest(parsed.text, images: parsed.images),
      observer: observer,
    );

    if (human) {
      console.stopThinking();
      console.endLine();
      if (result.status == RunStatus.blocked) {
        console.error('blocked: ${result.reason ?? 'unknown'}');
      } else if (result.status == RunStatus.incomplete &&
          result.answer != null) {
        console.answer(result.answer!);
      }
      console.status(
        _statusText(observer!, result, agent.session),
        kind: result.status.wire,
      );
      return result.status == RunStatus.complete ? 0 : 1;
    }

    switch (result.status) {
      case RunStatus.blocked:
        errSink.writeln('blocked: ${result.reason ?? 'unknown'}');
        _printTimings(errSink, result);
        _printSession(errSink, agent.session);
        return 1;
      case RunStatus.incomplete:
        outSink.writeln(result.answer ?? '');
        errSink.writeln('incomplete: ${result.reason ?? 'incomplete'}');
        _printTimings(errSink, result);
        _printSession(errSink, agent.session);
        return 1;
      case RunStatus.complete:
        outSink.writeln(result.answer ?? '');
        _printTimings(errSink, result);
        _printSession(errSink, agent.session);
        return 0;
    }
  } finally {
    // Reap any background job this one-shot run started (C3/C8).
    await agent.dispose();
    if (provider is ClosableProvider) (provider as ClosableProvider).close();
  }
}

/// The outcome of an interactive session (C6).
final class ReplOutcome {
  ReplOutcome({
    required this.exitCode,
    required this.runs,
    required this.session,
  });
  final int exitCode;
  final List<RunResult> runs;
  final Session session;
}

/// C6: the interactive CLI. Reads lines from [input]; a line starting with
/// `/` is a command, any other line is a goal run inside the current session.
/// Answers go to [out]; diagnostics, plan, and status go to [err].
///
/// On a real terminal ([interactive] plus [rawInput]) the default human
/// surface is the full-screen TUI ([tui]): a scrollable transcript, a
/// multi-line editor, and a fixed status footer. With `tui: false` the older
/// inline surface uses a [LineEditor] and the normal scrollback. Off a
/// terminal the plain line path is used unchanged.
Future<ReplOutcome> runRepl({
  required Config config,
  required Stream<String> input,
  Stream<List<int>>? rawInput,
  bool interactive = false,
  bool tui = false,
  StringSink? out,
  StringSink? err,
  Provider Function(ProviderConfig config)? providerFactory,
  Session? session,
  bool verbose = false,
  bool human = false,
  bool echoInput = false,
  List<String>? callLog,
  Reliability? reliability,
}) async {
  final factory = providerFactory ?? providerFor;
  final useTui = tui && human && interactive && rawInput != null;
  final ConsoleSurface surface = useTui
      ? TuiConsole(
          width: (stdout.hasTerminal ? stdout.terminalColumns : 80).clamp(
            20,
            500,
          ),
        )
      : Console(
          out: out ?? stdout,
          // Automate surface: stderr is the log, so timestamp every line (C6).
          err: human ? (err ?? stderr) : StampingSink(err ?? stderr),
          ansi: human,
          spinner: human,
        );
  final repl = _Repl(
    config: config,
    console: surface,
    provider: factory(config.provider),
    providerFactory: factory,
    session: session ?? Session.create(workspaceRoot: config.workspaceRoot),
    verbose: verbose,
    human: human,
    interactive: interactive,
    tui: useTui,
    echoInput: echoInput,
    callLog: callLog,
    reliability: reliability,
  );
  final ReplOutcome outcome;
  try {
    outcome = await repl.start(input: input, rawInput: rawInput);
  } finally {
    // C2: release the transport of the provider the session ends on. A
    // provider replaced earlier was closed by `_rebuildProvider`.
    final current = repl.provider;
    if (current is ClosableProvider) (current as ClosableProvider).close();
  }
  // C6: on the automate surface, log the session id on close so the next run
  // can resume it with `--session <id>`.
  if (!human) _printSession(repl.console.err, outcome.session);
  return outcome;
}

/// The mutable REPL state shared by the piped line path and the interactive
/// raw-keyboard path: the session, the assembled agent, and the command
/// dispatch. Keeping it in one place means both surfaces behave identically.
final class _Repl {
  _Repl({
    required this.config,
    required this.console,
    required this.provider,
    required this.providerFactory,
    required this.session,
    required this.verbose,
    required this.human,
    required this.interactive,
    required this.tui,
    required this.echoInput,
    this.callLog,
    this.reliability,
  }) {
    workspaceRoot = session.workspaceRoot;
    diagnostics = Diagnostics(
      enabled: verbose,
      sink: human ? console.diagnostic : console.err.writeln,
      // The automate log records the full LLM traffic; the human surface
      // keeps diagnostics to brief routing even with /verbose on.
      traceContent: !human,
    );
    agent = _build();
  }

  /// Mutable so a session-level command (`/workspace`, `/context`, or a
  /// provider/model switch) can rebuild the agent with an updated setting
  /// (C6).
  Config config;
  final ConsoleSurface console;

  /// Installed while the TUI runs (C6): present a modal popup over the frame
  /// and resolve with the chosen value, or null when cancelled. The
  /// selection commands (`/provider`, `/model`, `/sessions`) go through here
  /// instead of printing their listings into the transcript.
  Future<String?> Function(TuiPopup popup)? showTuiPopup;

  /// Installed while the TUI runs (C6): present a masked one-line modal (an
  /// API key) and resolve with the entered value, or null when skipped. The
  /// value never reaches the transcript or the config file.
  Future<String?> Function(TuiPrompt prompt)? showTuiPrompt;

  /// Rebuilt on `/provider` and `/model`; kept in sync with
  /// [providerFactory].
  Provider provider;
  final Provider Function(ProviderConfig config) providerFactory;
  final bool verbose;
  final bool human;
  final bool interactive;
  final bool tui;
  final bool echoInput;
  final List<String>? callLog;
  final Reliability? reliability;

  final List<RunResult> runs = [];
  late final Diagnostics diagnostics;

  /// Background jobs shared across agent rebuilds (a workspace change must
  /// not orphan a running dev server); reaped when the session closes (C8).
  final JobRegistry jobs = JobRegistry();

  Session session;
  late String workspaceRoot;
  late PropAgent agent;

  /// C6: non-zero when the final run was blocked and delivered nothing;
  /// reset to zero by any later run that delivers an answer.
  int exitCode = 0;

  PropAgent _build() => PropAgent.assemble(
    config: config.copyWith(workspaceRoot: workspaceRoot),
    provider: provider,
    session: session,
    callLog: callLog,
    diagnostics: diagnostics,
    reliability: reliability,
    jobs: jobs,
  );

  /// C2/C6: rebuild the provider and the agent after `/provider` or `/model`,
  /// releasing the replaced adapter's transport.
  void _rebuildProvider() {
    final previous = provider;
    provider = providerFactory(config.provider);
    if (previous is ClosableProvider) (previous as ClosableProvider).close();
    agent = _build();
  }

  Future<ReplOutcome> start({
    required Stream<String> input,
    Stream<List<int>>? rawInput,
  }) {
    if (tui && rawInput != null) {
      return _tui(rawInput);
    }
    if (human) {
      // The greeting: version first, then the repo link (C6, build identity).
      console.banner('Sudoer $kBuildLabel');
      console.header(kRepoUrl);
      console.header(config.provider.display);
      console.header('workspace $workspaceRoot');
      console.header('Type a goal, or /help. Ctrl+C to quit.');
    }
    if (human && interactive && rawInput != null) {
      return _interactive(rawInput);
    }
    return _stream(input);
  }

  /// The full-screen path. [Program] owns raw mode, the alternate screen,
  /// bracketed paste, and SIGINT; the app owns the layout and the run queue.
  /// On the way out any in-flight run is cancelled and awaited before the
  /// console is closed, so no callback can write into a dead frame.
  Future<ReplOutcome> _tui(Stream<List<int>> rawInput) async {
    final terminal = console as TuiConsole;
    // Program owns the screen and lifecycle; KeyReader owns the keyboard so
    // escape sequences, bracketed paste, and control bytes are decoded
    // correctly before they reach the editor.
    final reader = KeyReader(rawInput);
    final program = Program(options: [withAltScreen(), withInput(null)]);
    final app = _TuiApp(repl: this, console: terminal, program: program);
    terminal.onChange = () => program.send(const _TuiRedraw());
    // C6: the selection commands render as popups over the frame instead of
    // dumping their listings into the transcript.
    showTuiPopup = app.showPopup;
    showTuiPrompt = app.showPrompt;
    app.model = _TuiModel(app);
    final running = program.run(app.model);
    final subscription = reader.keys.listen(
      (key) {
        final msg = _tuiMessage(key);
        if (msg != null) program.send(msg);
      },
      onDone: () => app.close(),
      onError: (Object _) => app.close(natural: false),
    );
    try {
      await running;
    } finally {
      showTuiPopup = null;
      showTuiPrompt = null;
      app.shutdown();
      await app.drained;
      await subscription.cancel();
      await reader.close();
      terminal.close();
      // The session is closing: reap every background job (C3/C8).
      await jobs.reapAll();
    }
    if (!app.naturalExit) exitCode = 130;
    return ReplOutcome(exitCode: exitCode, runs: runs, session: session);
  }

  /// Dispatch one submitted TUI turn. The caller has already echoed the user
  /// line; this mirrors the inline path's command/goal/shell split and returns
  /// false when the session should close.
  Future<bool> submitTui(String line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return true;
    if (trimmed.startsWith('!')) {
      console.startThinking('running command');
      try {
        await _shell(trimmed.substring(1).trim());
      } finally {
        console.stopThinking();
      }
      return true;
    }
    if (trimmed.startsWith('/')) {
      if (_isCompact(trimmed)) {
        await _compact();
        return true;
      }
      // The selection commands open popups on the TUI surface (C6); the
      // inline and automate surfaces keep their line listings.
      if (await _tuiModal(trimmed)) return true;
      return _command(trimmed);
    }
    final embedded = embeddedCommand(line);
    if (embedded != null) {
      console.info(
        "note: '$embedded' is on a continuation line, so this is a "
        'multi-line goal, not a command (commands must be one line)',
      );
    }
    await _runGoal(line);
    return true;
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

    final subscription = input.listen(
      (raw) {
        // A cancel is never buffered: while a run is in flight it reaches that
        // run at once. Sent while idle it is a no-op, so a buffered `/cancel`
        // cannot leak into the next goal.
        if (_isCancel(raw)) {
          if (running) session.cancel.cancel();
          return;
        }
        queue.add(raw);
        notify();
      },
      onDone: () {
        inputDone = true;
        notify();
      },
    );

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

    final subscription = reader.keys.listen(
      (key) {
        if (stopped) return;
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
                console.info(
                  "note: '$embedded' is on a continuation line, so "
                  'this is a multi-line goal, not a command (commands must be '
                  'one line)',
                );
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
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
    );

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

  /// True when [line] opens a modal popup on the TUI surface (C6): these
  /// commands run without a model turn, so the app stays idle while the
  /// popup owns the keyboard. Only the bare command qualifies; an explicit
  /// argument (`/provider ollama`) keeps the direct path.
  bool isTuiModal(String line) {
    if (!tui || showTuiPopup == null) return false;
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 1) return false;
    return const {
      '/provider',
      '/model',
      '/sessions',
      '/resume',
      '/help',
      '/plan',
    }.contains(parts.first);
  }

  /// Handle the popup commands; returns true when the line was consumed.
  Future<bool> _tuiModal(String line) async {
    if (!isTuiModal(line)) return false;
    switch (line.trim().split(RegExp(r'\s+')).first) {
      case '/provider':
        await _pickProvider();
      case '/model':
        await _pickModel();
      case '/sessions':
      case '/resume':
        await _pickSession();
      case '/help':
        await showTuiPopup!(
          TuiPopup(
            title: 'Help',
            items: [
              for (final helpLine in _helpLines)
                TuiPopupItem(value: helpLine, label: helpLine),
            ],
            selectable: false,
          ),
        );
      case '/plan':
        final plan = session.plan;
        await showTuiPopup!(
          TuiPopup(
            title: 'Plan',
            items: [
              if (plan.isEmpty)
                const TuiPopupItem(value: '(no plan)', label: '(no plan)')
              else
                for (final item in plan)
                  TuiPopupItem(
                    value: item.text,
                    label: '- [${item.done ? 'x' : ' '}] ${item.text}',
                  ),
            ],
            selectable: false,
          ),
        );
    }
    return true;
  }

  /// C2/C6: the `/provider` popup — every preset, filterable, with the key
  /// state (never a value) as the detail column. Choosing a preset whose key
  /// is missing prompts for it (masked) before the switch applies; cancelling
  /// the picker changes nothing.
  Future<void> _pickProvider() async {
    final picked = await showTuiPopup!(
      TuiPopup(
        title: 'Provider',
        items: providerPopupItems(current: config.provider),
      ),
    );
    if (picked == null) return;
    await _maybeAskProviderKey(picked);
    _providerCommand(picked);
  }

  /// C2/C6: prompt for the key a provider switch needs but cannot resolve
  /// (config, auth store, env). Enter validates and stores a good key in the
  /// auth store, so the switch lands ready to call; Esc or an empty Enter
  /// skips — the switch still applies and the usual missing-key hint shows,
  /// because a switch is never fatal. The entered value is masked while
  /// typing and never echoed afterwards.
  Future<void> _maybeAskProviderKey(String presetId) async {
    final ask = showTuiPrompt;
    if (ask == null) return;
    final preset = providerPreset(presetId);
    if (preset == null ||
        !shouldPromptForKey(preset, current: config.provider)) {
      return;
    }
    final entered = await ask(
      TuiPrompt(
        title: 'API key for ${preset.name}',
        note: 'stored in the auth store; never echoed',
      ),
    );
    final key = entered?.trim();
    if (key == null || key.isEmpty) return; // skipped: switch without a key
    final problem = apiKeyProblem(key);
    if (problem != null) {
      console.error('invalid API key: $problem');
      return;
    }
    try {
      AuthStore().setKey(preset.id, key);
      console.info('key stored for ${preset.id} (auth store)');
    } on Object catch (e) {
      console.error('cannot store key: ${e.runtimeType}');
    }
  }

  /// C2/C6: the `/model` popup for the current provider's catalog. A preset
  /// with no catalog falls back to the listing text.
  Future<void> _pickModel() async {
    final preset =
        providerPreset(config.provider.preset) ??
        presetForConfig(config.provider);
    if (preset.models.isEmpty) {
      _modelCommand(null);
      return;
    }
    final picked = await showTuiPopup!(
      TuiPopup(
        title: 'Model · ${preset.id}',
        items: [
          for (final model in preset.models)
            TuiPopupItem(
              value: model.id,
              label: model.id,
              detail: formatContextWindow(model.contextWindow),
              active: model.id == config.provider.model,
            ),
        ],
      ),
    );
    if (picked != null) _modelCommand(picked);
  }

  /// C6: the `/sessions` / `/resume` popup; Enter resumes the chosen session.
  Future<void> _pickSession() async {
    final ids = Session.list(config.sessionDir);
    if (ids.isEmpty) {
      console.info('no sessions');
      return;
    }
    final picked = await showTuiPopup!(
      TuiPopup(
        title: 'Sessions',
        items: [
          for (final id in ids)
            TuiPopupItem(value: id, label: id, active: id == session.id),
        ],
      ),
    );
    if (picked != null) _resumeSession(picked);
  }

  /// C6: switch to a saved session, rebuilding the agent and replaying the
  /// transcript. Shared by `/resume <id>` and the session popup.
  void _resumeSession(String id) {
    try {
      session = Session.load(config.sessionDir, id);
      agent = _build();
      if (console case TuiConsole tui) {
        tui.resetTranscript();
        tui.replay(session.transcript);
      }
      console.info('resumed ${session.id}');
    } on Object catch (e) {
      console.error('cannot resume: $e');
    }
  }

  /// C2/C6: list providers, or switch to a preset (rebuilding the provider
  /// and agent). A missing key is reported, not fatal: the switch still
  /// applies, and the first call explains how to add one.
  void _providerCommand(String? argument) {
    if (argument == null) {
      console.info(providerListText(current: config.provider));
      console.info(
        'switch: /provider <id> (session only; '
        '`sudoer-prop --setup` persists and sets keys)',
      );
      return;
    }
    final preset = providerPreset(argument);
    if (preset == null) {
      console.error('unknown provider: $argument');
      return;
    }
    if (preset.id == config.provider.preset) {
      console.info('already using ${preset.id}');
      return;
    }
    if (preset.baseUrl == null) {
      console.error(
        '${preset.id} needs a base URL; '
        'use `sudoer-prop --setup`',
      );
      return;
    }
    final nextModel = preset.defaultModel.isEmpty
        ? config.provider.model
        : preset.defaultModel;
    final nextWindow =
        preset.model(nextModel)?.contextWindow ?? kDefaultContextWindow;
    final provider = ProviderConfig(
      kind: preset.kind,
      model: nextModel,
      contextWindow: nextWindow,
      preset: preset.id,
      baseUrl: preset.baseUrl,
      sampling: config.provider.sampling,
    );
    config = config.copyWith(provider: provider);
    _rebuildProvider();
    diagnostics.event('C2 provider', 'provider -> ${preset.id}');
    console.info('provider: ${preset.id}  model: $nextModel');
    final hint = missingKeyHint(provider);
    if (hint != null) console.info(hint);
  }

  /// C2/C6: list the current provider's models, or switch model. An id the
  /// catalog does not know keeps the current context window.
  void _modelCommand(String? argument) {
    final preset =
        providerPreset(config.provider.preset) ??
        presetForConfig(config.provider);
    if (argument == null) {
      console.info(modelListText(preset, current: config.provider.model));
      console.info('switch: /model <id> (session only)');
      return;
    }
    if (argument.trim().isEmpty) {
      console.error('usage: /model <id>');
      return;
    }
    final info = preset.model(argument);
    final window = info?.contextWindow ?? config.provider.contextWindow;
    config = config.copyWith(
      provider: config.provider.copyWith(
        model: argument,
        contextWindow: window,
      ),
    );
    _rebuildProvider();
    diagnostics.event('C2 provider', 'model -> $argument');
    console.info('model: $argument  [${formatContextWindow(window)} context]');
    if (info == null) {
      console.info('(not in the catalog; kept the previous context window)');
    }
  }

  /// C4/C6: print the active context strategy and, under CLM, the live file.
  void _printContext() {
    final path = agent.contextFilePath;
    if (path == null) {
      console.info('context: harness (built-in clip / clear / fold ladder)');
      return;
    }
    final file = File(path);
    final size = file.existsSync() ? file.lengthSync() : 0;
    console.info(
      'context: clm (model-managed) ${shortPath(path, 60)} ${size}B',
    );
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
      console.info(
        agent.contextFilePath == null
            ? 'nothing to compact'
            : 'context is model-managed (CLM); the agent compacts it itself',
      );
    } else {
      console.info(
        '↺ compacted ${info.steps} earlier steps '
        '(${_compactCount(info.beforeTokens)} → '
        '${_compactCount(info.afterTokens)} tokens)',
      );
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

  /// Run one goal and render its result. Shared by both surfaces. `@path`
  /// tokens are stripped by C7 and attached to this goal only; a bad token
  /// reports locally and the goal is not submitted. Returns null then.
  Future<RunResult?> _runGoal(String goal) async {
    final parsed = _parseGoalInput(goal);
    if (parsed == null) return null;
    final observer = human ? _CliObserver(console) : null;
    final RunResult result;
    try {
      result = await agent.run(
        RunRequest(parsed.text, images: parsed.images),
        observer: observer,
      );
    } on Object catch (e) {
      if (human) {
        console.stopThinking();
        console.endLine();
      }
      // StepFailure normally becomes a blocked result inside the loop; this
      // is the last line of defence for a transport-level exception. Never
      // interpolate the raw error: it can contain a header or key value.
      final detail = switch (e) {
        StepFailure(:final message) => message,
        ConfigException(:final message) => message,
        GuardDeniedException(:final message) => message,
        _ => '${e.runtimeType}',
      };
      console.error('run failed: $detail');
      if (human) console.stopThinking();
      exitCode = 1;
      return null;
    }
    runs.add(result);
    // Any non-`complete` final run makes the process exit non-zero (C6);
    // a later `complete` run resets it.
    exitCode = result.status == RunStatus.complete ? 0 : 1;
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
      console.status(
        _statusText(observer!, result, session),
        kind: result.status.wire,
      );
    } else {
      _render(console.out, console.err, result);
    }
    return result;
  }

  /// C7: strip `@path` tokens from a goal line and load the images they name.
  /// Reports a bad token locally and returns null (the goal is not submitted).
  ParsedGoal? _parseGoalInput(String line) {
    try {
      return parseGoal(line);
    } on FormatException catch (e) {
      console.error(e.message);
      return null;
    }
  }

  List<String> get _helpLines => helpLines(interactive: interactive, tui: tui);

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
        if (console case TuiConsole tui) tui.resetTranscript();
        console.info('new session ${session.id}');
      case '/sessions':
        final ids = Session.list(config.sessionDir);
        console.info(ids.isEmpty ? 'no sessions' : ids.join('\n'));
      case '/resume':
        if (argument == null) {
          console.error('usage: /resume <id>');
        } else {
          _resumeSession(argument);
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
        final argument = parts.length > 1
            ? line.substring(command.length).trim()
            : null;
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
        console.info(
          'session ${session.id}: '
          '${session.transcript.length} entries, '
          '${session.plan.length} plan items, '
          'last run ${last?.status.wire ?? 'none'}',
        );
      case '/context':
        if (argument == null) {
          _printContext();
          break;
        }
        final mode = switch (argument) {
          'harness' => ContextMode.harness,
          'clm' => ContextMode.clm,
          _ => null,
        };
        if (mode == null) {
          console.error('usage: /context [harness|clm]');
          break;
        }
        config = config.copyWith(context: config.context.copyWith(mode: mode));
        agent = _build();
        // Switch to CLM: materialize the live mirror now (when there is a
        // transcript to mirror) so the file exists before the next run.
        if (mode == ContextMode.clm && session.transcript.isNotEmpty) {
          try {
            agent.contextLog?.write(session.transcript);
          } on Object catch (e) {
            console.error('cannot write context file: $e');
          }
        }
        diagnostics.event('C4 context', 'mode -> ${mode.name}');
        _printContext();
      case '/provider':
        _providerCommand(argument);
      case '/model':
        _modelCommand(argument);
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

/// Translate a raw-terminal [Key] into the message the TUI model consumes.
Msg? _tuiMessage(Key key) => switch (key.kind) {
  KeyKind.rune => KeyPressMsg(
    TeaKey(code: KeyCode.rune, text: String.fromCharCode(key.rune)),
  ),
  KeyKind.enter => KeyPressMsg(const TeaKey(code: KeyCode.enter)),
  // A bare LF is another form of Enter (some terminals send it instead of
  // CR); an explicit Alt+Enter or Kitty Shift+Enter adds a line.
  KeyKind.newline => KeyPressMsg(const TeaKey(code: KeyCode.enter)),
  KeyKind.altEnter => KeyPressMsg(
    const TeaKey(code: KeyCode.enter, modifiers: {KeyMod.shift}),
  ),
  KeyKind.paste => PasteMsg(key.text),
  KeyKind.backspace => KeyPressMsg(const TeaKey(code: KeyCode.backspace)),
  KeyKind.delete => KeyPressMsg(const TeaKey(code: KeyCode.delete)),
  KeyKind.left => KeyPressMsg(const TeaKey(code: KeyCode.left)),
  KeyKind.right => KeyPressMsg(const TeaKey(code: KeyCode.right)),
  KeyKind.up => KeyPressMsg(const TeaKey(code: KeyCode.up)),
  KeyKind.down => KeyPressMsg(const TeaKey(code: KeyCode.down)),
  KeyKind.home => KeyPressMsg(const TeaKey(code: KeyCode.home)),
  KeyKind.end => KeyPressMsg(const TeaKey(code: KeyCode.end)),
  KeyKind.pageUp => KeyPressMsg(const TeaKey(code: KeyCode.pageUp)),
  KeyKind.pageDown => KeyPressMsg(const TeaKey(code: KeyCode.pageDown)),
  KeyKind.esc => KeyPressMsg(const TeaKey(code: KeyCode.escape)),
  KeyKind.tab => KeyPressMsg(const TeaKey(code: KeyCode.tab)),
  KeyKind.ctrlC => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 'c', modifiers: {KeyMod.ctrl}),
  ),
  KeyKind.ctrlD => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 'd', modifiers: {KeyMod.ctrl}),
  ),
  // Crush-style shortcuts (C6): help, models, sessions, new session, and
  // the command palette.
  KeyKind.ctrlG => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 'g', modifiers: {KeyMod.ctrl}),
  ),
  KeyKind.ctrlL => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 'l', modifiers: {KeyMod.ctrl}),
  ),
  KeyKind.ctrlN => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 'n', modifiers: {KeyMod.ctrl}),
  ),
  KeyKind.ctrlP => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 'p', modifiers: {KeyMod.ctrl}),
  ),
  KeyKind.ctrlS => KeyPressMsg(
    const TeaKey(code: KeyCode.rune, text: 's', modifiers: {KeyMod.ctrl}),
  ),
  KeyKind.other => null,
  KeyKind.mouse => _mouseMsg(key.mouse!),
};

/// Map a decoded mouse report onto the TUI messages. Wheel events are the
/// point: they scroll the surface under the interaction (the transcript, or
/// an open popup). Clicks and motion are decoded but otherwise unused.
Msg? _mouseMsg(MousePointer event) {
  final button = switch (event.button) {
    0 => MouseButton.left,
    1 => MouseButton.middle,
    2 => MouseButton.right,
    64 => MouseButton.wheelUp,
    65 => MouseButton.wheelDown,
    66 => MouseButton.wheelLeft,
    67 => MouseButton.wheelRight,
    _ => MouseButton.none,
  };
  final mouse = Mouse(
    x: event.x > 0 ? event.x - 1 : 0,
    y: event.y > 0 ? event.y - 1 : 0,
    button: button,
  );
  return switch (event.action) {
    MouseAction.press => button == MouseButton.none
        ? null
        : (button == MouseButton.wheelUp ||
              button == MouseButton.wheelDown ||
              button == MouseButton.wheelLeft ||
              button == MouseButton.wheelRight)
        ? MouseWheelMsg(mouse)
        : MouseClickMsg(mouse),
    MouseAction.release => MouseReleaseMsg(mouse),
    MouseAction.motion => MouseMotionMsg(mouse),
  };
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
  final ConsoleSurface console;
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
  void onPlan(List<PlanItem> plan) => console.touch();

  @override
  void onStep(int step, int stalls, int stallBudget) {
    this.step = step;
    this.stalls = stalls;
    this.stallBudget = stallBudget;
    // Keep the phase word alone so the elapsed time reads right after it; the
    // step/budget rides behind the timer as the spinner detail.
    console.updateThinking('thinking');
    console.setDetail(
      stalls > 0 ? 'step $step · stalled $stalls/$stallBudget' : 'step $step',
    );
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
    console.info(
      '↺ compacted $steps earlier steps into a summary '
      '(${_compactCount(beforeTokens)} → ${_compactCount(afterTokens)} tokens)',
    );
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
      name == 'run_command' ? 'running command' : 'running $name',
    );
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
  final stall = o.stalls > 0 ? ' (stalled ${o.stalls}/${o.stallBudget})' : '';
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

/// Print the run's measured total as a plain `timing:` line on stderr,
/// leaving stdout untouched for the automate surface. Per-response and
/// per-tool timings are emitted inline by the C2 trace as they happen
/// (automate verbose), so only the `run` total lands here.
void _printTimings(StringSink err, RunResult result) {
  for (final timing in result.timings) {
    if (timing.label != 'run') continue;
    err.writeln('timing: ${timing.label} ${formatDuration(timing.duration)}');
  }
}

/// C6: on the automate surface, log the session id at exit so the run can be
/// resumed by copy-pasting `--session <id>`. Goes to stderr, keeping stdout
/// the clean answer surface.
void _printSession(StringSink err, Session session) {
  err.writeln('session ${session.id} (resume: --session ${session.id})');
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

/// The local `/` commands the REPL understands. `/quit` is not listed: it is
/// a hidden alias of `/exit` (still accepted, so old muscle memory keeps
/// working) and never advertised.
const Set<String> kReplCommands = {
  '/help',
  '/exit',
  '/new',
  '/sessions',
  '/resume',
  '/plan',
  '/status',
  '/provider',
  '/model',
  '/context',
  '/compact',
  '/diff',
  '/workspace',
  '/verbose',
};

/// One command and its one-line description, used by the TUI's slash
/// completion menu and its command palette (C6). Surface-aware the same way
/// [helpLines] is: on the TUI the selection commands open popups.
typedef ReplCommandInfo = (String command, String description);

List<ReplCommandInfo> replCommandCatalog({
  required bool interactive,
  bool tui = false,
}) => [
  ('/help', tui ? 'show this help (popup)' : 'show this help'),
  ('/exit', 'persist and close the session, then exit'),
  ('/new', 'start a new session'),
  ('/sessions', tui ? 'pick a saved session to resume' : 'list saved sessions'),
  (
    '/resume',
    tui
        ? '[id] pick or switch to a saved session'
        : '<id> switch to a saved session',
  ),
  ('/plan', tui ? 'show the current plan (popup)' : 'print the current plan'),
  ('/status', 'print the session status'),
  (
    '/provider',
    tui
        ? '[id] pick or switch the LLM provider preset'
        : '[id] list or switch the LLM provider preset',
  ),
  (
    '/model',
    tui ? '[id] pick or switch the model' : '[id] list or switch the model',
  ),
  ('/context', '[mode] show or switch the context strategy'),
  ('/diff', '[path] show workspace changes'),
  if (!interactive) ('/cancel', 'cancel the in-flight run'),
  ('/compact', 'fold earlier context into a brief now'),
  ('/workspace', '[dir] print or change the workspace root'),
  ('/verbose', 'on|off emit per-step routing'),
];

/// The `/help` lines for a surface. `/cancel` is a command on the automate
/// surface only; the human CLI interrupts with a double `Esc`, so it is not
/// listed there. On the TUI the selection commands open popups (C6), so their
/// descriptions say "pick" instead of "list".
List<String> helpLines({required bool interactive, bool tui = false}) => [
  'Commands:',
  '  /help            show this help${tui ? ' (popup)' : ''}',
  '  /exit            persist and close the session, then exit',
  '  /new             start a new session',
  if (tui)
    '  /sessions        pick a saved session to resume'
  else
    '  /sessions        list saved sessions',
  if (tui)
    '  /resume [id]     pick or switch to a saved session'
  else
    '  /resume <id>     switch to a saved session',
  if (tui)
    '  /plan            show the current plan (popup)'
  else
    '  /plan            print the current plan',
  '  /status          print the session status',
  if (tui)
    '  /provider [id]   pick or switch the LLM provider preset (C2)'
  else
    '  /provider [id]   list or switch the LLM provider preset (C2)',
  if (tui)
    '  /model [id]      pick or switch the model for the current provider'
  else
    '  /model [id]      list or switch the model for the current provider',
  '  /context [mode]  show or switch the context strategy (harness|clm)',
  '  /diff [path]     show workspace changes against the session baseline',
  if (!interactive) '  /cancel          cancel the in-flight run',
  '  /compact         fold earlier context into a brief now',
  '  /workspace [dir] print or change the workspace root',
  '  /verbose on|off  emit per-step routing on stderr',
  '  @path            attach an image (png/jpg/jpeg/gif/webp) to the goal',
  if (interactive)
    '  !<command>       run a shell command here (not sent to the model)',
  'Anything else is a goal for the agent.',
  if (tui) ...[
    '  (Shift+Enter or Alt+Enter adds a line; Enter sends; Esc cancels)',
    '  Shortcuts: Ctrl+P commands · Ctrl+L models · Ctrl+S sessions ·',
    '  Ctrl+N new session · Ctrl+G help · type / for command completion',
  ] else if (interactive)
    '  (end a line with \\ to continue the goal on the next line)',
];

/// True when [line] invokes the on-demand compaction command.
bool _isCompact(String line) => line.split(RegExp(r'\s+')).first == '/compact';

/// True when [line] is the cancel command. Intercepted on the piped surface
/// before buffering so it can interrupt an in-flight run (C6).
bool _isCancel(String line) => line.split(RegExp(r'\s+')).first == '/cancel';

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
