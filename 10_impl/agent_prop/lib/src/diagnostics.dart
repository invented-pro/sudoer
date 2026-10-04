/// C6: verbose diagnostics. The interface owns the toggle; every component
/// reports its internal routing and behavior through [event] using its own
/// component id (`C1`–`C8`). The hot path is free when disabled, which is the
/// default.
final class Diagnostics {
  Diagnostics({this.enabled = false, this.sink});

  /// A shared, permanently silent instance for callers that do not wire one
  /// (the gate, unit tests, and any direct assembly).
  static final Diagnostics silent = Diagnostics();

  /// Whether events are emitted. Toggled live by `/verbose on|off` (C6).
  bool enabled;

  /// Where events go; a null sink drops them even when enabled.
  final void Function(String line)? sink;

  /// Emit one diagnostic line for [component], or drop it when disabled.
  /// [detail] should be a short, single-line summary.
  void event(String component, String detail) {
    if (!enabled) return;
    sink?.call('[$component] $detail');
  }
}

/// Collapse [text] to a single line and cap it at [max] characters, for
/// diagnostics where the full value would be noise.
String brief(Object? text, [int max = 120]) {
  final flat = (text ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? '${flat.substring(0, max)}…' : flat;
}
