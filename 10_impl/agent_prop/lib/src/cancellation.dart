import 'dart:async';

import 'errors.dart';

/// C8: a one-shot, resettable cancellation signal.
///
/// The interface (C6) raises it (`/cancel`, a double `Esc`) and the run resets
/// it at the start of each goal. The loop (C1) passes it into the in-flight
/// call, where the provider (C2) or a long-running tool (C3) races it so the
/// call aborts at once instead of waiting for the model or command to finish.
final class CancelSignal {
  Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called; an in-flight call can race it.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }

  /// Clear a previous cancel so the next goal starts fresh.
  void reset() {
    _completer = Completer<void>();
  }
}

/// Race [future] against [cancel]: when the signal fires, the returned future
/// fails with a cancelled [StepFailure] instead of waiting for [future].
Future<T> raceCancel<T>(Future<T> future, CancelSignal? cancel) {
  if (cancel == null) return future;
  if (cancel.isCancelled) {
    return Future<T>.error(const StepFailure.cancelled('cancelled by user'));
  }
  return Future.any<T>([
    future,
    cancel.whenCancelled.then<T>(
        (_) => throw const StepFailure.cancelled('cancelled by user')),
  ]);
}

/// Race [source] against [cancel]: the returned stream forwards [source]'s
/// events until the signal fires, then errors with a cancelled [StepFailure]
/// and cancels the source subscription (which aborts the underlying request).
Stream<T> raceCancelStream<T>(Stream<T> source, CancelSignal? cancel) {
  if (cancel == null) return source;
  final controller = StreamController<T>();
  StreamSubscription<T>? subscription;
  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    subscription?.cancel();
    controller.close();
  }

  subscription = source.listen(
    controller.add,
    onError: (Object error, StackTrace stack) {
      controller.addError(error, stack);
      close();
    },
    onDone: close,
  );
  cancel.whenCancelled.then((_) {
    if (closed) return;
    controller.addError(const StepFailure.cancelled('cancelled by user'));
    close();
  });
  return controller.stream;
}
