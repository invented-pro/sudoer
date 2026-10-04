import 'config.dart';
import 'context.dart';
import 'diagnostics.dart';
import 'loop.dart';
import 'models.dart';
import 'providers/provider.dart';
import 'reliability.dart';
import 'session.dart';
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
  });

  final Config config;
  final Provider provider;
  final ToolRegistry tools;
  final AgentLoop loop;
  final Session session;
  final Diagnostics diagnostics;

  factory PropAgent.assemble({
    required Config config,
    required Provider provider,
    Session? session,
    List<String>? callLog,
    Diagnostics? diagnostics,
    Future<bool> Function(String tool, String reason)? authorize,
  }) {
    final diag = diagnostics ?? Diagnostics.silent;
    final current =
        session ?? Session.create(workspaceRoot: config.workspaceRoot);
    final guard = WorkspaceGuard(config.workspaceRoot)
      ..allowOutside = current.allowOutsideWorkspace;
    final network = NetworkGuard(
      enabled: config.web.enabled,
      denyHosts: config.web.denyHosts,
    );
    final tools = ToolRegistry(
      workspaceRoot: config.workspaceRoot,
      guard: guard,
      tools: [
        ...builtinTools(guard),
        if (config.web.enabled) ...webTools(guard, network, config.web),
      ],
      callLog: callLog,
    );
    final context = ContextAssembler(
      contextWindow: config.provider.contextWindow,
      diagnostics: diag,
    );
    final loop = AgentLoop(
      model: config.provider.model,
      provider: provider,
      tools: tools,
      context: context,
      authorize: authorize,
      diagnostics: diag,
    );
    return PropAgent._(
      config: config,
      provider: provider,
      tools: tools,
      loop: loop,
      session: current,
      diagnostics: diag,
    );
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
    diagnostics.event('C2 provider',
        '${config.provider.kind.name} model=${config.provider.model}');
    diagnostics.event('C3 tools',
        'workspace=${session.workspaceRoot} stallBudget=$kStallBudget '
        'ceiling=$kStepCeiling');
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
}
