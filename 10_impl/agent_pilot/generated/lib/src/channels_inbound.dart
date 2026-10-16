import 'dart:io';

import 'channels.dart';
import 'models.dart';
import 'pilot_agent.dart';
import 'pilot_runtime.dart';
import 'pilot_commands.dart' show gateChain;
import 'providers/provider.dart';
import 'reliability.dart';
import 'session.dart';

/// C6/C10: the inbound channel path — one implementation shared by the REST
/// server and the gate's injected channel adapters. If the channel is
/// enabled and the sender is permitted the text becomes a goal in that
/// channel's session and runs exactly like a CLI goal; otherwise it is
/// refused, logged, and never reaches the model.
final class InboundOutcome {
  const InboundOutcome({
    required this.allowed,
    this.sessionId,
    this.answer,
    this.reason,
  });
  final bool allowed;
  final String? sessionId;
  final String? answer;
  final String? reason;
}

/// Handle one inbound message against [runtime]. The runner drives the
/// goal (the shipped assembly; the gate injects its scripted chain through
/// the same env seam every other surface uses).
Future<InboundOutcome> handleInbound(
  PilotRuntime runtime,
  String channelId,
  String from,
  String text, {
  List<Provider>? chain,
  Reliability? reliability,
}) async {
  final config = runtime.config;
  final channel = config.channels
      .where((entry) => entry.id == channelId)
      .firstOrNull;
  if (channel == null) {
    runtime.log.emitChannel(channelId, 'unknown');
    runtime.decisions.add('channel_denied', 'channel', detail: channelId);
    return const InboundOutcome(allowed: false, reason: 'unknown channel');
  }
  if (!channel.enabled ||
      (channel.allowFrom.isNotEmpty && !channel.allowFrom.contains(from))) {
    // Refused: logged, and its text never reaches the model (C10).
    runtime.log.emitChannel(channelId, 'denied', from: from);
    runtime.decisions.add('channel_denied', 'channel', detail: channelId);
    return const InboundOutcome(
        allowed: false, reason: 'sender not permitted on this channel');
  }
  runtime.log.emitChannel(channelId, 'in', from: from);

  // The channel's session: resolved or created on first contact (C5).
  var sessionId = runtime.sessions.sessionForChannel(channelId);
  Session session;
  if (sessionId == null) {
    session = Session.create(workspaceRoot: config.primaryRoot)
      ..channel = channelId;
    sessionId = session.id;
  } else {
    try {
      session = Session.load(config.sessionDir, sessionId);
    } on Object {
      session = Session.create(workspaceRoot: config.primaryRoot)
        ..channel = channelId;
      sessionId = session.id;
    }
  }
  final answer = await runInSession(
    runtime,
    session,
    text,
    chain: chain,
    reliability: reliability,
  );
  // Deliver the reply back to the channel (C6): recorded by the injected
  // sink in the gate, POSTed to the outbound URL in production.
  await runtime.deliverToChannel(
    channel: Channel(
      id: channel.id,
      outboundUrl: channel.outboundUrl,
      outboundSecret: channel.outboundSecret,
      allowFrom: channel.allowFrom,
    ),
    to: from,
    message: answer ?? '',
  );
  return InboundOutcome(allowed: true, sessionId: sessionId, answer: answer);
}

/// Run one goal in [session] on the Pilot assembly, persisting and indexing
/// the session (the automation path; the gate injects its chain).
Future<String?> runInSession(
  PilotRuntime runtime,
  Session session,
  String goal, {
  List<Provider>? chain,
  Reliability? reliability,
}) async {
  final agent = PilotAgent.assemble(
    runtime: runtime,
    session: session,
    chain: chain ?? gateChain(),
    reliability: reliability ?? _envReliability(),
  );
  try {
    final result = await agent.run(RunRequest(goal));
    return result.answer;
  } finally {
    await agent.dispose();
  }
}

Reliability? _envReliability() =>
    Platform.environment['SUDOER_SCRIPT_FILE'] == null
        ? null
        : const Reliability(sleep: _noSleep);

Future<void> _noSleep(Duration _) async {}
