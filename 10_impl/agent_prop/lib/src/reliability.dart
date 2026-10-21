import 'dart:async';

import 'errors.dart';

/// C8: compiled-in Prop guards. Deliberately not configuration.
///
/// A run is bounded by *stalls*, not by raw step count: it continues while
/// steps make progress and ends after [kStallBudget] consecutive steps that
/// make none (repeats, errors, timeouts). [kStepCeiling] is only a runaway
/// safety net, so long productive work is never cut off. Timeouts are chosen
/// by tool class: [kModelTimeout] for provider calls, [kBuildTimeout] for
/// `run_command`, so compilers and test suites can finish.
const int kStallBudget = 3;
const int kStepCeiling = 1000;

/// Provider-call inactivity bound. Generous because some OpenAI-compatible
/// endpoints do not stream tool-call `arguments` incrementally: they generate
/// a whole call (e.g. a `write` of a full file) server-side and emit it in one
/// chunk, so a perfectly healthy endpoint can stay silent for 30-45s. A
/// tighter bound (it was 30s) turned every large write into a guaranteed
/// timeout, and retrying could not help because the silence is deterministic.
const Duration kModelTimeout = Duration(seconds: 120);
const Duration kBuildTimeout = Duration(minutes: 10);

/// Network calls (C3 web tools) use their own class: long enough for a slow
/// page, far shorter than the build timeout.
const Duration kWebTimeout = Duration(seconds: 20);

/// Runaway net for a model call (C8): the adapter bounds it by a send
/// deadline plus per-chunk inactivity, but an endpoint can keep a queued
/// request alive with trickle bytes forever. This generous total cap — well
/// above the inactivity bound, like the step ceiling above the stall budget —
/// turns such a hang into a recoverable timeout instead.
const Duration kModelTotalCap = Duration(minutes: 10);

/// C8: a provider *timeout* is a transport failure, not model behavior, so it
/// is retried in place before it reaches the loop and counts as a non-progress
/// step. A compiled-in retry count with exponential backoff — a brief endpoint
/// outage is survived, while a persistent one still exhausts the retries and
/// then stalls. The sleep is injected so the gate and tests pin it to a no-op.
const int kProviderTimeoutRetries = 2;
const Duration kProviderRetryBackoff = Duration(milliseconds: 500);
const int kProviderRetryBackoffFactor = 4;
const Duration kProviderRetryBackoffCap = Duration(seconds: 30);

Future<void> _delay(Duration duration) => Future<void>.delayed(duration);

/// Web tool bounds, compiled-in like the other guards (C8): the most bytes a
/// fetch will read and the most search results a query will return.
const int kWebMaxBytes = 256 * 1024;
const int kWebMaxResults = 10;

/// Wraps a step in a timeout and normalizes a real [TimeoutException] into a
/// recoverable [StepFailure]; simulated failures from a provider pass through
/// unchanged.
final class Reliability {
  const Reliability({
    this.modelTimeout = kModelTimeout,
    this.buildTimeout = kBuildTimeout,
    this.providerTimeoutRetries = kProviderTimeoutRetries,
    this.retryBackoff = kProviderRetryBackoff,
    this.sleep = _delay,
  });

  final Duration modelTimeout;
  final Duration buildTimeout;

  /// How many times a provider timeout is retried in place before it counts
  /// toward the stall budget (C8).
  final int providerTimeoutRetries;

  /// The first retry delay; each later retry multiplies it by
  /// [kProviderRetryBackoffFactor], capped at [kProviderRetryBackoffCap].
  final Duration retryBackoff;

  /// The backoff sleep, injected so the gate and tests never actually wait.
  final Future<void> Function(Duration) sleep;

  /// The backoff before the [attempt]-th retry (1-based).
  Duration backoffFor(int attempt) {
    var delay = retryBackoff;
    for (var i = 1; i < attempt; i++) {
      delay *= kProviderRetryBackoffFactor;
      if (delay >= kProviderRetryBackoffCap) return kProviderRetryBackoffCap;
    }
    return delay;
  }

  /// Model calls are bounded by the adapter itself (C2/C8): a total
  /// deadline on the request/response-head phase and an *inactivity*
  /// timeout reset on each streamed chunk, so a long generation is never
  /// cut off while it is producing. The only outer bound is the generous
  /// [kModelTotalCap] runaway net for trickle-kept queues.
  Future<T> guardModel<T>(Future<T> Function() call) =>
      _guard(call, kModelTotalCap);

  Future<T> guardTool<T>(Future<T> Function() call, Duration timeout) =>
      _guard(call, timeout);

  Future<T> _guard<T>(Future<T> Function() call, Duration timeout) async {
    try {
      return await call().timeout(timeout);
    } on TimeoutException {
      throw const StepFailure.timeout('step timed out');
    }
  }
}
