/// Error taxonomy shared across components.
library;

/// How a step failed, per C2/C8: `timeout` is recoverable (the loop
/// re-iterates); `unrecoverable` blocks the run; `cancelled` means the user
/// aborted the in-flight call, which ends the run without blocking it.
enum FailureKind { timeout, unrecoverable, cancelled }

class StepFailure implements Exception {
  const StepFailure(this.kind, this.message);
  const StepFailure.timeout(String message)
      : this(FailureKind.timeout, message);
  const StepFailure.unrecoverable(String message)
      : this(FailureKind.unrecoverable, message);
  const StepFailure.cancelled(String message)
      : this(FailureKind.cancelled, message);

  final FailureKind kind;
  final String message;

  @override
  String toString() => 'StepFailure(${kind.name}): $message';
}

/// Raised by context (C4) when the prompt cannot fit the window; blocks (C1).
class ContextOverflowException implements Exception {
  const ContextOverflowException(this.message);
  final String message;
  @override
  String toString() => 'ContextOverflowException: $message';
}

/// Which guard a denial came from. The workspace guard can be opened by the
/// human for the session; the network guard cannot (C3, C6).
enum GuardArea { workspace, network }

/// Raised by a tool (C3) when a call crosses a guard boundary; blocks.
class GuardDeniedException implements Exception {
  const GuardDeniedException(this.message, {this.area = GuardArea.workspace});
  final String message;
  final GuardArea area;
  @override
  String toString() => 'GuardDeniedException: $message';
}

/// Raised by the config loader (C6) when configuration is invalid.
class ConfigException implements Exception {
  const ConfigException(this.message);
  final String message;
  @override
  String toString() => 'ConfigException: $message';
}

/// Raised by the config loader (C6) when the selected config file does not
/// exist. Carries the resolved [path] so the surface can tell the user where
/// it looked and show a sample to create.
class ConfigNotFoundException extends ConfigException {
  const ConfigNotFoundException(this.path)
      : super('config file not found: $path');
  final String path;
}
