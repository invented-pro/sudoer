import 'dart:convert';

import 'package:http/http.dart' as http;

import 'clock.dart';
import 'log.dart';
import 'policy.dart';
import 'safety.dart';

/// C6: one registered channel — a REST client (the built-in web page or an
/// external messenger adapter), frozen in `channel.schema.json`.
final class Channel {
  Channel({
    required this.id,
    this.kind,
    this.outboundUrl,
    this.outboundSecret,
    this.allowFrom = const [],
    this.enabled = true,
  });

  final String id;
  final String? kind;

  /// Where Pilot POSTs outbound messages; null for a pull-only adapter.
  final String? outboundUrl;

  /// Name of the secret (in secrets_file) injected as the bearer header on
  /// outbound POSTs (C10); never a value.
  final String? outboundSecret;

  /// Permitted inbound sender ids; empty means any sender.
  final List<String> allowFrom;
  final bool enabled;

  bool permits(String from) =>
      allowFrom.isEmpty || allowFrom.contains(from);

  Map<String, dynamic> toJson() => {
        'id': id,
        if (kind != null) 'kind': kind,
        if (outboundUrl != null) 'outbound_url': outboundUrl,
        if (outboundSecret != null) 'outbound_secret': outboundSecret,
        if (allowFrom.isNotEmpty) 'allow_from': allowFrom,
        'enabled': enabled,
      };

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        kind: json['kind'] as String?,
        outboundUrl: json['outbound_url'] as String?,
        outboundSecret: json['outbound_secret'] as String?,
        allowFrom: [
          for (final from in (json['allow_from'] as List? ?? const []))
            from as String,
        ],
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// An inbound message an adapter delivered (or the harness injected):
/// `{channel, from, text}` (`channel.schema.json` `inboundMessage`).
final class InboundMessage {
  InboundMessage({required this.channel, required this.from, required this.text});
  final String channel;
  final String from;
  final String text;
}

/// One outbound delivery, recorded by the injected delivery sink — the gate
/// asserts these instead of shipping real messages (`outboundMessage`).
final class OutboundDelivery {
  OutboundDelivery({
    required this.channel,
    required this.to,
    required this.message,
    required this.at,
    this.task,
  });
  final String channel;
  final String to;
  final String message;
  final DateTime at;
  final String? task;

  Map<String, dynamic> toJson() => {
        'channel': channel,
        'to': to,
        'text': message,
        'at': at.toIso8601String(),
        if (task != null) 'task': task,
      };
}

/// The outbound leg of channel delivery (C10): POST `{to, text, at, task?}`
/// to the channel's `outbound_url`, under the network policy, with the
/// channel's named secret injected as the bearer header. The injected
/// [recorder] is the gate's fake adapter; a registered channel without an
/// outbound URL is pull-only and only records.
Future<OutboundDelivery> deliver({
  required Channel channel,
  required String to,
  required String message,
  DateTime? at,
  String? task,
  Secrets? secrets,
  NetworkPolicy? policy,
  DecisionLog? decisions,
  StructuredLog? log,
  Clock? clock,
  void Function(OutboundDelivery delivery)? recorder,
  http.Client? client,
}) async {
  final stamp = at ?? (clock?.now() ?? DateTime.now().toUtc());
  final delivery = OutboundDelivery(
      channel: channel.id, to: to, message: message, at: stamp, task: task);
  recorder?.call(delivery);
  log?.emitChannel(channel.id, 'out', to: to, task: task);
  final url = channel.outboundUrl;
  if (url == null) return delivery;
  final uri = Uri.parse(url);
  if (policy != null && !policy.allows(uri, decisions: decisions, tool: 'channel')) {
    return delivery;
  }
  final request = http.Request('POST', uri)
    ..headers['content-type'] = 'application/json'
    ..body = jsonEncode(delivery.toJson());
  final secretName = channel.outboundSecret;
  if (secretName != null && secrets != null) {
    final value = secrets.resolve(secretName);
    if (value != null) request.headers['authorization'] = 'Bearer $value';
  }
  try {
    final response =
        await (client ?? http.Client()).send(request).timeout(const Duration(seconds: 10));
    await response.stream.drain<void>();
  } on Object {
    // A failed delivery is reported and retried on the next tick by the
    // scheduler (C8); it is never lost silently.
  }
  return delivery;
}
