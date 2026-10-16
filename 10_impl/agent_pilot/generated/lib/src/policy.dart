import 'dart:async';
import 'dart:convert';

import 'clock.dart';
import 'safety.dart';

/// C10: the generalized network policy for every egress tool — the web
/// tools, the `http` connector, and the outbound leg of channel delivery.
/// `deny_hosts` merges with `web.deny_hosts` (union); `allow_hosts`, when
/// non-empty, inverts the policy to a whitelist. The host check runs before
/// any socket opens, so denial stays offline and deterministic.
final class NetworkPolicy {
  NetworkPolicy({
    List<String> denyHosts = const [],
    List<String> allowHosts = const [],
  })  : denyHosts = List.unmodifiable(denyHosts),
        allowHosts = List.unmodifiable(allowHosts);

  final List<String> denyHosts;
  final List<String> allowHosts;

  /// Merge the web guard's list with `policy.network.deny_hosts` (union).
  NetworkPolicy mergedWith(Iterable<String> webDeny) => NetworkPolicy(
        denyHosts: {...denyHosts, ...webDeny}.toList(),
        allowHosts: allowHosts,
      );

  /// Exact host or `.`-prefixed suffix match, as the Prop web guard.
  bool isDenied(String host) {
    final h = host.toLowerCase();
    for (final entry in denyHosts) {
      final e = entry.toLowerCase();
      if (e.startsWith('.')) {
        if (h == e.substring(1) || h.endsWith(e)) return true;
      } else if (h == e) {
        return true;
      }
    }
    return false;
  }

  bool isAllowed(String host) {
    if (allowHosts.isEmpty) return true;
    final h = host.toLowerCase();
    return allowHosts.any((entry) {
      final e = entry.toLowerCase();
      if (e.startsWith('.')) return h.endsWith(e);
      return h == e;
    });
  }

  /// The verdict for [uri]; when denied, the human-readable reason.
  (bool, String?) verdict(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return (false, 'only http/https URLs can be fetched');
    }
    if (isDenied(uri.host)) {
      return (false, 'egress to ${uri.host} is blocked by the deny list');
    }
    if (!isAllowed(uri.host)) {
      return (false,
          'egress to ${uri.host} is not on policy.network.allow_hosts');
    }
    return (true, null);
  }

  /// Deny or record the decision. True when egress is permitted.
  bool allows(Uri uri, {required String tool, DecisionLog? decisions}) {
    final (ok, reason) = verdict(uri);
    if (!ok) {
      decisions?.add('network_denied', tool, detail: uri.host);
    }
    return ok;
  }
}

/// How the caller can obtain a confirmation (C10). The CLI human surface can
/// ask and wait; the web/channel surface asks and blocks to a compiled-in
/// timeout; the automate surface, the HTTP API, and any other
/// non-interactive context deny immediately.
enum ConfirmSurface { interactive, channel, nonInteractive }

/// One matcher: a tool name plus an optional substring that must appear in
/// the JSON-encoded arguments (C10).
final class ConfirmMatcher {
  ConfirmMatcher({required this.tool, this.arg});
  final String tool;
  final String? arg;

  bool hits(String name, String argumentsJson) =>
      tool == name && (arg == null || argumentsJson.contains(arg!));
}

/// The confirmation gate (C10). Empty by default — confirm is off. A
/// dispatch that matches requires explicit user confirmation: granted on the
/// interactive surface by the caller's callback, asked in the channel and
/// blocked to a compiled-in 120s timeout (deny) on the channel surface, and
/// denied immediately everywhere else.
final class ConfirmPolicy {
  ConfirmPolicy({
    List<ConfirmMatcher> matchers = const [],
    this.clock = const SystemClock(),
  }) : matchers = List.unmodifiable(matchers);

  final List<ConfirmMatcher> matchers;
  final Clock clock;

  /// Compiled-in block-and-ask bound on the channel surface; the timeout
  /// result is deny (gate frozen-constants table).
  Duration get confirmTimeout => const Duration(seconds: 120);

  bool get off => matchers.isEmpty;

  /// The matcher that hits this call, or null.
  ConfirmMatcher? matchFor(String name, Map<String, dynamic> arguments) {
    final json = argumentsJson(arguments);
    for (final matcher in matchers) {
      if (matcher.hits(name, json)) return matcher;
    }
    return null;
  }

  /// Evaluate a matched call. Returns the decision event
  /// (`confirm_granted` | `confirm_denied`), already logged.
  Future<String> evaluate(
    ConfirmMatcher matcher,
    ConfirmSurface surface, {
    required String tool,
    required Future<bool> Function() askInteractive,
    required Future<bool> Function(String question) askChannel,
    DecisionLog? decisions,
  }) async {
    void log(String event) => decisions?.add(event, tool, detail: matcher.arg);
    switch (surface) {
      case ConfirmSurface.nonInteractive:
        log('confirm_denied');
        return 'confirm_denied';
      case ConfirmSurface.interactive:
        log('confirm_asked');
        final granted = await askInteractive();
        log(granted ? 'confirm_granted' : 'confirm_denied');
        return granted ? 'confirm_granted' : 'confirm_denied';
      case ConfirmSurface.channel:
        log('confirm_asked');
        var granted = false;
        try {
          granted = await askChannel('Confirm: run $tool'
                  '${matcher.arg == null ? '' : ' (${matcher.arg})'}? yes/no')
              .timeout(confirmTimeout);
        } on TimeoutException {
          granted = false; // the timeout result is deny (C10)
        }
        log(granted ? 'confirm_granted' : 'confirm_denied');
        return granted ? 'confirm_granted' : 'confirm_denied';
    }
  }

  /// Encode arguments deterministically for matcher matching.
  static String argumentsJson(Map<String, dynamic> arguments) =>
      jsonEncode(arguments);
}
