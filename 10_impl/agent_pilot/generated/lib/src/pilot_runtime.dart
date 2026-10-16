import 'channels.dart' as channels;
import 'clock.dart';
import 'embedder.dart';
import 'log.dart';
import 'notifier.dart';
import 'pilot_config.dart';
import 'policy.dart';
import 'safety.dart';
import 'platform_wake.dart';
import 'sessions_index.dart';

/// The outbound channel delivery function: the real adapter POST in
/// production, a recorder under the gate (C6/C10).
typedef ChannelDelivery = Future<channels.OutboundDelivery> Function(
  channels.OutboundDelivery delivery,
  channels.Channel channel,
);

/// The Pilot runtime: every injected environment dependency (clock, sleeper,
/// notifier, scheduler, channel delivery, embedder) and every shared store,
/// wired once per process and handed to the components that need them
/// (C8: injected environment; the gate pins fakes).
final class PilotRuntime {
  PilotRuntime._({
    required this.config,
    required this.clock,
    required this.scheduler,
    required this.notifier,
    required this.log,
    required this.decisions,
    required this.secrets,
    required this.sessions,
  });

  /// The live configuration; `PUT /config` swaps it at a run boundary
  /// (C6/C10). Reads that matter per-request go through [config].
  PilotConfig config;
  final Clock clock;
  final Scheduler scheduler;
  final Notifier notifier;
  final StructuredLog log;
  final DecisionLog decisions;
  final Secrets secrets;
  final SessionsIndex sessions;

  /// Ordered names of dispatched tool calls (the gate's `expect.tools`).
  final List<String> callLog = [];

  /// The pinned memory embedder, when the harness injects one (C9/gate);
  /// null means production resolution from the config.
  Embedder? embedder;

  /// The outbound leg of channel delivery (C6), bound at assembly.
  late final ChannelDelivery deliver;

  /// Wire a runtime over [config], defaulting every injected dependency to
  /// its production implementation; the gate passes fakes for each.
  factory PilotRuntime.assemble(
    PilotConfig config, {
    Clock? clock,
    Scheduler? scheduler,
    Notifier? notifier,
    StructuredLog? log,
    DecisionLog? decisions,
    Secrets? secrets,
    ChannelDelivery? deliver,
    SessionsIndex? sessions,
  }) {
    final resolvedClock = clock ?? const SystemClock();
    final resolvedDecisions =
        decisions ?? DecisionLog(config.policyLog, resolvedClock);
    final runtime = PilotRuntime._(
      config: config,
      clock: resolvedClock,
      scheduler: scheduler ?? systemScheduler(),
      notifier: notifier ?? SystemNotifier.platform(),
      log: log ?? StructuredLog(config.logFile, resolvedClock),
      decisions: resolvedDecisions,
      secrets: secrets ??
          Secrets(config.secretsFile, resolvedClock,
              onDecision: (event, tool, detail) =>
                  resolvedDecisions.add(event, tool, detail: detail)),
      sessions: sessions ?? SessionsIndex(config.sessionDir),
    );
    runtime.deliver =
        deliver ?? (delivery, channel) => _postDelivery(runtime, delivery, channel);
    return runtime;
  }

  /// Deliver one message over [channel] (the `send` tool, a task's delivery):
  /// recorded, logged, then POSTed under the network policy with the
  /// channel's named secret injected (C10).
  Future<channels.OutboundDelivery> deliverToChannel({
    required channels.Channel channel,
    required String to,
    required String message,
    DateTime? at,
    String? task,
  }) =>
      deliver(
        channels.OutboundDelivery(
          channel: channel.id,
          to: to,
          message: message,
          at: at ?? clock.now(),
          task: task,
        ),
        channel,
      );

  /// The merged network policy: `policy.network` merged with the web guard's
  /// deny list (union) (C10).
  NetworkPolicy get network => NetworkPolicy(
        denyHosts: config.networkDenyHosts,
        allowHosts: config.networkAllowHosts,
      ).mergedWith(config.web.denyHosts);

  /// The confirm gate from the configured matchers (C10).
  ConfirmPolicy get confirm => ConfirmPolicy(
        matchers: [
          for (final matcher in config.confirmMatchers)
            ConfirmMatcher(tool: matcher.tool, arg: matcher.arg),
        ],
        clock: clock,
      );
}

/// The production delivery: POST through the channel adapter with this
/// runtime's policy, secrets, decision log, and structured log.
Future<channels.OutboundDelivery> _postDelivery(
  PilotRuntime runtime,
  channels.OutboundDelivery delivery,
  channels.Channel channel,
) =>
    channels.deliver(
      channel: channel,
      to: delivery.to,
      message: delivery.message,
      at: delivery.at,
      task: delivery.task,
      secrets: runtime.secrets,
      policy: runtime.network,
      decisions: runtime.decisions,
      log: runtime.log,
      clock: runtime.clock,
    );
