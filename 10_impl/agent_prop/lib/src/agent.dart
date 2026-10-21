import 'package:path/path.dart' as p;

import 'clm.dart';
import 'config.dart';
import 'context.dart';
import 'diagnostics.dart';
import 'loop.dart';
import 'models.dart';
import 'providers/provider.dart';
import 'reliability.dart';
import 'session.dart';
import 'tools/baseline.dart';
import 'tools/job.dart';
import 'tools/tool.dart';
import 'tools/web.dart';

/// The assembled Prop agent: C1–C8 wired per `00_bp/agent_prop.md`. It runs
/// goals inside a continuous, persistent session.
final class PropAgent {
  PropAgent._({
    required this.config,
    required this.provider,
    required this.tools,
    required this.loop,
    required this.session,
    required this.diagnostics,
    required this.baseline,
    required this.ownsJobs,
    this.contextLog,
  });

  final Config config;
  final Provider provider;
  final ToolRegistry tools;
  final AgentLoop loop;
  final Session session;
  final Diagnostics diagnostics;

  /// C4 (CLM): the model-owned live context file, or null under the harness
  /// ladder.
  final ContextLog? contextLog;

  /// The live context file path (CLM only), for the interface and tests.
  String? get contextFilePath => contextLog?.file.path;

  /// The workspace snapshot backing `diff`/`restore` (C3/C5): captured at
  /// session open, refreshed when the workspace root changes, recorded in the
  /// session file by its opaque handle. Never shown to the model.
  final WorkspaceBaseline baseline;

  /// True when this agent created (and therefore reaps) the job registry.
  final bool ownsJobs;

  factory PropAgent.assemble({
    required Config config,
    required Provider provider,
    Session? session,
    List<String>? callLog,
    Diagnostics? diagnostics,
    JobRegistry? jobs,
    Reliability? reliability,
  }) {
    final diag = diagnostics ?? Diagnostics.silent;
    final current =
        session ?? Session.create(workspaceRoot: config.workspaceRoot);
    final guard = WorkspaceGuard(config.workspaceRoot);
    final network = NetworkGuard(
      enabled: config.web.enabled,
      denyHosts: config.web.denyHosts,
    );
    final baseline = _adoptBaseline(current, config);
    final registry = jobs;
    final tools = ToolRegistry(
      workspaceRoot: config.workspaceRoot,
      guard: guard,
      tools: [
        ...builtinTools(
          guard,
          baseline: baseline,
          jobs: registry,
          buildTimeout: reliability?.buildTimeout,
        ),
        if (config.web.enabled) ...webTools(guard, network, config.web),
      ],
      callLog: callLog,
    );
    // C4: choose the context strategy. Under CLM the model owns the live
    // context, so the prompt gains the CLM section and the loop mirrors the
    // transcript to an editable file; under the default the pinned ladder
    // prompt is used unchanged.
    final clm = config.context.mode == ContextMode.clm;
    final contextLog = clm
        ? ContextLog(
            ContextLog.fileFor(config),
            workspaceRoot: config.workspaceRoot,
          )
        : null;
    final systemPrompt = clm
        ? '$kPropSystemPrompt\n\n${clmContextSection(contextPath: contextLog!.displayPath, window: config.provider.contextWindow, strategy: config.context.strategy)}'
        : kPropSystemPrompt;
    final context = ContextAssembler(
      contextWindow: config.provider.contextWindow,
      systemPrompt: systemPrompt,
      modelManagedContext: clm,
      diagnostics: diag,
    );
    final loop = AgentLoop(
      model: config.provider.model,
      provider: provider,
      tools: tools,
      context: context,
      contextLog: contextLog,
      reliability: reliability ?? const Reliability(),
      diagnostics: diag,
    );
    return PropAgent._(
      config: config,
      provider: provider,
      tools: tools,
      loop: loop,
      session: current,
      diagnostics: diag,
      baseline: baseline,
      ownsJobs: registry == null,
      contextLog: contextLog,
    );
  }

  /// Adopt the session's recorded baseline when it still matches this
  /// workspace; otherwise capture a fresh snapshot and record its handle
  /// (C5: refreshed only when the workspace root changes).
  static WorkspaceBaseline _adoptBaseline(Session session, Config config) {
    final root = p.normalize(p.absolute(config.workspaceRoot));
    final handle = session.baseline;
    if (handle != null) {
      final loaded = WorkspaceBaseline.load(config.sessionDir, handle);
      if (loaded != null && loaded.root == root) return loaded;
    }
    final captured = WorkspaceBaseline.capture(config.workspaceRoot);
    session.baseline = captured.save(config.sessionDir);
    return captured;
  }

  /// Reap background jobs when this agent owns them (C3/C8): the session is
  /// closing, so no child process outlives the agent.
  Future<void> dispose() async {
    if (ownsJobs) await tools.reapJobs();
  }

  /// Run one goal inside the session, then persist the updated session (C5).
  ///
  /// A [RunObserver] receives streamed text and live status for a human
  /// interface; automation passes none and takes the one-shot provider path.
  Future<RunResult> run(RunRequest request, {RunObserver? observer}) async {
    diagnostics.event(
      'C6 interface',
      'goal="${brief(request.goal)}" -> session ${session.id}',
    );
    diagnostics.event(
      'C2 provider',
      '${config.provider.kind.name} model=${config.provider.model}',
    );
    diagnostics.event(
      'C3 tools',
      'workspace=${session.workspaceRoot} stallBudget=$kStallBudget '
          'ceiling=$kStepCeiling',
    );
    final result = await loop.run(request, session, observer: observer);
    session.updatedAt = DateTime.now().toUtc();
    final path = session.save(config.sessionDir);
    diagnostics.event(
      'C5 session',
      'persisted ${session.transcript.length} entries, ${session.plan.length} plan items -> $path',
    );
    diagnostics.event(
      'C6 interface',
      'result ${result.status.wire}'
          '${result.reason != null ? ' (${result.reason})' : ''}',
    );
    return result;
  }

  /// C4/C6: fold older context into a brief on demand (`/compact`), below the
  /// automatic watermark. Returns null when there is nothing to fold.
  Future<CompactionInfo?> compact() => loop.compact(session, force: true);

  /// C6/C3: the workspace changes behind the `/diff` command. [path] scopes
  /// to one workspace-relative file; a path escaping the workspace throws.
  String workspaceDiff({String? path}) {
    if (path == null) {
      final text = baseline.diffWorkspace();
      return text.isEmpty ? 'no changes' : text;
    }
    final file = tools.guard.resolve(path);
    final relative = p.posix.joinAll(
      p
          .relative(
            file.path,
            from: p.normalize(p.absolute(session.workspaceRoot)),
          )
          .split(p.separator),
    );
    final text = baseline.diffWorkspace(only: relative);
    return text.isEmpty ? 'no changes ($path matches the baseline)' : text;
  }
}
