import 'dart:async';

/// C8/C11: the injected clock. Every due-time comparison, log timestamp,
/// task resolution, and confirm timeout goes through [now]; no wall-clock
/// path is hardcoded, so the gate pins a [FakeClock] and stays deterministic.
abstract interface class Clock {
  DateTime now();

  /// The clock's sleep: real wall time for the system clock, immediate for
  /// the fake (the gate never waits).
  Future<void> sleep(Duration duration);
}

/// The production clock.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();

  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
}

/// The gate's pinned clock: [initial] advanced only by [advance].
final class FakeClock implements Clock {
  FakeClock(DateTime initial) : _now = initial;

  DateTime _now;

  DateTime get time => _now;

  @override
  DateTime now() => _now;

  /// Advance the pinned instant; durations may be negative.
  void advance(Duration duration) {
    _now = _now.add(duration);
  }

  @override
  Future<void> sleep(Duration duration) async {}
}
