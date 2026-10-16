import 'config.dart';
import 'context.dart';
import 'diagnostics.dart';
import 'embedder.dart';
import 'errors.dart';
import 'interface.dart' show ReplAgent;
import 'loop.dart';
import 'memory.dart';
import 'models.dart';
import 'pilot_config.dart';
import 'pilot_context.dart';
import 'pilot_runtime.dart';
import 'channels.dart';
import 'policy.dart';
import 'providers/chain.dart';
import 'providers/provider.dart';
import 'providers/ollama.dart';
import 'providers/openai_compatible.dart';
import 'reliability.dart';
import 'scheduler.dart';
import 'session.dart';
import 'sessions_index.dart';
import 'safety.dart';
import 'tools/baseline.dart';
import 'tools/job.dart';
import 'tools/memory_tools.dart';
import 'tools/pilot_tools.dart';
import 'tools/tool.dart';
import 'tools/web.dart';

/// C1–C11 assembled: Prop's coding agent with the personal tier wired in —
/// the provider chain (C2), the policy layer (C10), memory + recall (C9),
/// the scheduler's tool (C11), and the audit hooks (C8). Every environment
/// dependency rides on the injected [PilotRuntime], so the gate pins fakes.
final class PilotAgent implements ReplAgent {
  PilotAgent._({
    required this.runtime,
    required this.provider,
    required this.tools,
    required this.loop,
    required this.session,
    required this.memory,
    required this.diagnostics,
    required this.baseline,
    required this.ownsJobs,
  });

  final PilotRuntime runtime;
  final Provider provider;
  final ToolRegistry tools;
  final AgentLoop loop;
  final Session session;
  final MemoryStore memory;
  final Diagnostics diagnostics;

  /// The workspace snapshot backing `diff`/`restore` (C3/C5).
  final WorkspaceBaseline baseline;
  final bool ownsJobs;

  PilotConfig get config => runtime.config;

  /// Assemble the agent for [session] over [runtime].
  ///
  /// [chain] overrides the provider chain (the gate injects its scripted
  /// chain here — harness-only, never config-reachable); when null the
  /// configured chain is built from [adapters] or the real provider
  /// adapters.
  factory PilotAgent.assemble({
    required PilotRuntime runtime,
    required Session session,
    List<Provider>? chain,
    Provider Function(ProviderConfig entry)? adapters,
    Embedder? embedder,
    List<String>? callLog,
    Diagnostics? diagnostics,
    JobRegistry? jobs,
    Reliability? reliability,
  }) {
    final config = runtime.config;
    final diag = diagnostics ?? Diagnostics.silent;
    final clock = runtime.clock;
    final guard = MultiRootGuard(config.workspaceRoots);
    final baseline = _adoptBaseline(session, config);

    // C2: the provider chain — injected, adapter-built, or the failover
    // chain over the real adapters.
    final providers = chain ??
        [
          for (final entry in config.chain)
            (adapters ?? defaultAdapter)(entry),
        ];
    final resolvedReliability = reliability ??
        Reliability(
          // C11: the clock is the injected sleep source; the gate's fake
          // clock no-ops it, so backoff never waits (C8).
          sleep: (duration) => clock.sleep(duration),
        );

    // C9: the memory store on the configured embedder — injected for the
    // gate (the deterministic fake / forced lexical fallback), the
    // configured kind for production.
    final resolvedEmbedder = embedder ??
        (config.embedder == null
            ? LocalEmbedder()
            : embedderFromConfig({
                'kind': config.embedder!.kind,
                'base_url': config.embedder!.baseUrl,
                'model': config.embedder!.model,
              }));
    final memory = MemoryStore(config.memoryDir, resolvedEmbedder);

    // C10: the merged network policy and the confirm gate. The confirm
    // surface is chosen by the caller's transport (CLI human can ask; the
    // API and automation deny); the default here is the non-interactive
    // one, and the CLI REPL rebuilds the agent with its own surface.
    final network = runtime.network;
    final confirm = runtime.confirm;

    final registryJobs = jobs;
    final tools = ToolRegistry(
      workspaceRoot: config.primaryRoot,
      guard: guard,
      callLog: callLog ?? runtime.callLog,
      audit: (call, outcome) {
        runtime.log.emitToolCall(call.name, outcome.outcome.wire,
            detail: outcome.outcome == Outcome.ok ? null : outcome.text,
            session: session.id);
      },
      tools: [
        // The Prop coding catalog, unchanged.
        ...builtinTools(
          guard,
          baseline: baseline,
          jobs: registryJobs,
          buildTimeout: resolvedReliability.buildTimeout,
        ),
        // The web tools under the merged policy (C10).
        if (config.web.enabled)
          ...webTools(
            guard,
            _NetworkGuardAdapter(network, runtime.decisions).check,
            config.web,
          ),
        // C9: the memory tools.
        ...memoryTools(memory, runtime.secrets),
        // C3/C10/C11: the personal tools.
        ...pilotTools(
          network: network,
          confirm: confirm,
          surface: ConfirmSurface.nonInteractive,
          secrets: runtime.secrets,
          decisions: runtime.decisions,
          notifier: runtime.notifier,
          tasks: TaskStore(config.tasksFile, clock),
          clock: clock,
          channels: {
            for (final channel in config.channels)
              channel.id: Channel(
                id: channel.id,
                kind: channel.kind,
                outboundUrl: channel.outboundUrl,
                outboundSecret: channel.outboundSecret,
                allowFrom: channel.allowFrom,
                enabled: channel.enabled,
              ),
          },
          deliverToChannel: (channelId, to, message, {task}) async {
            final channel = config.channels
                .where((c) => c.id == channelId)
                .firstOrNull;
            if (channel == null) return;
            await runtime.deliverToChannel(
              channel: Channel(
                id: channel.id,
                outboundUrl: channel.outboundUrl,
                outboundSecret: channel.outboundSecret,
                allowFrom: channel.allowFrom,
              ),
              to: to,
              message: message,
              task: task,
            );
          },
          log: runtime.log,
        ),
      ],
    );

    // C4: the Pilot prompt with the recall segment slot.
    final context = ContextAssembler(
      contextWindow: config.primary.contextWindow,
      systemPrompt: kPilotSystemPrompt,
      diagnostics: diag,
    );

    final loop = AgentLoop(
      model: config.primary.model,
      provider: ChainProvider(
        providers: providers,
        reliability: resolvedReliability,
        clock: clock,
        onCall: (index, outcome, failover) => runtime.log.emitProviderCall(
            index, outcome,
            failover: failover, session: session.id),
      ),
      tools: tools,
      context: context,
      reliability: resolvedReliability,
      diagnostics: diag,
    );

    return PilotAgent._(
      runtime: runtime,
      provider: providers.first,
      tools: tools,
      loop: loop,
      session: session,
      memory: memory,
      diagnostics: diag,
      baseline: baseline,
      ownsJobs: registryJobs == null,
    );
  }

  /// The production adapter map (C2): the configured kind selects the
  /// adapter; a chain may mix them.
  static Provider defaultAdapter(ProviderConfig entry) =>
      switch (entry.kind) {
        ProviderKind.openAiCompatible => OpenAiCompatibleProvider(entry),
        ProviderKind.ollama => OllamaProvider(entry),
      };

  /// C4/C9: compute the goal's recall segment once, before the run's first
  /// provider call. The segment is goal-stable for the whole run; omitted
  /// when memory is empty or finds nothing.
  void primeRecall(String goal) {
    final context = loop.context;
    final hits = memory.recall(goal);
    context.recallSegment =
        renderRecallSegment([
      for (final note in hits) (note.id, note.title, note.body),
    ]);
  }

  /// Clear the recall segment (the next goal computes its own).
  void clearRecall() => loop.context.recallSegment = null;

  /// Run one goal: prime recall, run the loop, persist and index the
  /// session, and log the run (C8). `system` marks a scheduler-fired goal.
  @override
  Future<RunResult> run(
    RunRequest request, {
    RunObserver? observer,
    bool system = false,
  }) async {
    runtime.log.emitRunStart(request.goal, session: session.id, system: system);
    primeRecall(request.goal);
    final result = await loop.run(request, session, observer: observer);
    clearRecall();
    session.updatedAt = DateTime.now().toUtc();
    final path = session.save(config.sessionDir);
    runtime.sessions.upsert(
      id: session.id,
      title: sessionTitle(session.transcript
          .whereType<UserEntry>()
          .map((entry) => entry.text)
          .firstOrNull ?? session.id),
      workspaceRoot: session.workspaceRoot,
      channel: session.channel,
      created: session.createdAt,
      updated: session.updatedAt,
      runs: runtime.sessions.byId(session.id)?['runs'] is int
          ? (runtime.sessions.byId(session.id)!['runs'] as int) + 1
          : 1,
      lastStatus: result.status.wire,
    );
    runtime.log.emitRunEnd(result.status.wire, _countSteps(session),
        answer: result.answer, session: session.id);
    diagnostics.event(
        'C5 session', 'persisted ${session.transcript.length} entries -> $path');
    return result;
  }

  static int _countSteps(Session session) => session.transcript
      .whereType<AssistantEntry>()
      .length;

  /// Adopt the session's recorded baseline when it still matches this
  /// workspace; otherwise capture a fresh one (C5).
  static WorkspaceBaseline _adoptBaseline(Session session, PilotConfig config) {
    final root = config.primaryRoot;
    final handle = session.baseline;
    if (handle != null) {
      final loaded = WorkspaceBaseline.load(config.sessionDir, handle);
      if (loaded != null && loaded.root == root) return loaded;
    }
    final captured = WorkspaceBaseline.capture(root);
    session.baseline = captured.save(config.sessionDir);
    return captured;
  }

  /// Reap background jobs when this agent owns them (C3/C8).
  @override
  Future<void> dispose() async {
    if (ownsJobs) await tools.reapJobs();
  }

  /// C4/C6: fold older context into a brief on demand (`/compact`).
  @override
  Future<CompactionInfo?> compact() => loop.compact(session, force: true);

  /// C6/C3: the workspace changes behind the `/diff` command.
  @override
  String workspaceDiff({String? path}) {
    if (path == null) {
      final text = baseline.diffWorkspace();
      return text.isEmpty ? 'no changes' : text;
    }
    final file = tools.guard.resolve(path);
    final relative = file.path;
    final text = baseline.diffWorkspace(only: relative);
    return text.isEmpty ? 'no changes ($path matches the baseline)' : text;
  }
}

/// The web tools' guard seam (C3) over the C10 policy: the guard shape the
/// Prop web tools expect, backed by the merged policy and the decision log.
class _NetworkGuardAdapter {
  _NetworkGuardAdapter(this._policy, this._decisions);
  final NetworkPolicy _policy;
  final DecisionLog _decisions;

  bool get enabled => true;

  bool allowsHost(String host) =>
      _policy.isAllowed(host) && !_policy.isDenied(host);

  void check(Uri uri) {
    if (!_policy.allows(uri, tool: 'web', decisions: _decisions)) {
      throw GuardDeniedException(
          'web egress to ${uri.host} is denied by network policy',
          area: GuardArea.network);
    }
  }
}
