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
const int kStepCeiling = 200;
const Duration kModelTimeout = Duration(seconds: 30);
const Duration kBuildTimeout = Duration(minutes: 10);

/// Network calls (C3 web tools) use their own class: long enough for a slow
/// page, far shorter than the build timeout.
const Duration kWebTimeout = Duration(seconds: 20);

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
  });

  final Duration modelTimeout;
  final Duration buildTimeout;

  Future<T> guardModel<T>(Future<T> Function() call) =>
      _guard(call, modelTimeout);

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
