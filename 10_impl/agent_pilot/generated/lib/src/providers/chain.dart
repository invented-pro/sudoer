import '../cancellation.dart';
import '../clock.dart';
import '../errors.dart';
import '../log.dart';
import '../models.dart';
import '../reliability.dart';
import 'provider.dart';

/// C2/C8: the ordered provider chain with retry, then failover. A call
/// retries in place with the compiled-in bounded backoff; once the retries
/// on one provider are spent — on a timeout *or* an unrecoverable failure —
/// the *same assembled prompt* goes to the next entry (the provider is
/// stateless, so failover is exact). Only when the chain is exhausted does
/// the failure surface, with Prop's semantics (timeout recoverable,
/// unrecoverable blocks). Every failover is observable through the
/// structured log (C8), never silent.
///
/// Streamed calls fail over only while no visible chunk has arrived; once
/// text has been delivered, a failure surfaces as a recoverable timeout
/// rather than re-streaming a partial answer from another backend (C2).
final class ChainProvider implements Provider {
  ChainProvider({
    required this.providers,
    required this.reliability,
    this.clock = const SystemClock(),
    this.onCall,
  });

  final List<Provider> providers;
  final Reliability reliability;
  final Clock clock;

  /// The `provider_call` sink: (chain index, outcome, failed over).
  final void Function(int index, String outcome, bool failover)? onCall;

  int _current = 0;

  /// The chain index the last successful call used (C2: a run starts and
  /// finishes on one provider; the index is diagnostics).
  int get current => _current;

  @override
  Future<ProviderResponse> complete(
    ProviderRequest request, {
    void Function(String delta)? onDelta,
    void Function(String delta)? onReasoning,
    CancelSignal? cancel,
  }) async {
    var streamed = false;
    // Forward deltas verbatim while recording that text has been delivered:
    // once it has, a failure never re-streams from another backend (C2).
    final observed = onDelta == null
        ? null
        : (String delta) {
            streamed = true;
            onDelta(delta);
          };
    final observedReasoning = onReasoning == null
        ? null
        : (String delta) {
            streamed = true;
            onReasoning(delta);
          };

    Object? last;
    for (var index = 0; index < providers.length; index++) {
      try {
        final response = await _callWithRetry(
          providers[index],
          request,
          index,
          failover: index > 0,
          onDelta: observed,
          onReasoning: observedReasoning,
          streamed: () => streamed,
          cancel: cancel,
        );
        _current = index;
        onCall?.call(index, 'ok', index > 0);
        return response;
      } on StepFailure catch (failure) {
        if (failure.kind == FailureKind.cancelled || streamed) rethrow;
        last = failure;
        onCall?.call(index, failure.kind.name, index + 1 < providers.length);
      }
    }
    throw last is StepFailure
        ? last
        : const StepFailure.unrecoverable('provider chain exhausted');
  }

  /// One provider, retried in place on timeout with the bounded backoff
  /// (C8: hidden retries never consume the loop's stall budget).
  Future<ProviderResponse> _callWithRetry(
    Provider provider,
    ProviderRequest request,
    int index, {
    required bool failover,
    required void Function(String delta)? onDelta,
    required void Function(String delta)? onReasoning,
    required bool Function() streamed,
    CancelSignal? cancel,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await reliability.guardModel(
          () => provider.complete(
            request,
            onDelta: onDelta,
            onReasoning: onReasoning,
            cancel: cancel,
          ),
        );
      } on StepFailure catch (failure) {
        if (failure.kind != FailureKind.timeout ||
            attempt >= reliability.providerTimeoutRetries ||
            streamed()) {
          rethrow;
        }
        attempt++;
        final delay = reliability.backoffFor(attempt);
        await reliability.sleep(delay);
      }
    }
  }
}

/// Wire the chain's `provider_call` events into the structured log (C8).
void Function(int, String, bool) chainLogger(StructuredLog log) =>
    (index, outcome, failover) =>
        log.emitProviderCall(index, outcome, failover: failover);
