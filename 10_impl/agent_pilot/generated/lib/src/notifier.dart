import 'dart:io';

/// C3: the desktop notifier, an injected adapter. `notify` is best-effort —
/// a failure or the absence of a notifier is a recoverable observation, not
/// a block. The gate's [FakeNotifier] records deliveries for assertions.
abstract interface class Notifier {
  /// True when a notification was delivered.
  bool notify(String title, String message);
}

/// The gate's recorder: nothing leaves the process.
final class FakeNotifier implements Notifier {
  final List<(String, String)> sent = [];

  @override
  bool notify(String title, String message) {
    sent.add((title, message));
    return true;
  }
}

/// The production notifier: `notify-send` (Linux), `osascript` (macOS), a
/// PowerShell toast (Windows). Returns false when the platform call fails.
final class SystemNotifier implements Notifier {
  SystemNotifier();

  /// Constructor mirror for [Notifier.system].
  static SystemNotifier platform() => SystemNotifier();

  @override
  bool notify(String title, String message) {
    try {
      final result = () {
      if (Platform.isMacOS) {
        final safeTitle = title.replaceAll('"', r'\"');
        final safeMessage = message.replaceAll('"', r'\"');
        return Process.runSync('osascript', [
          '-e',
          'display notification "$safeMessage" with title "$safeTitle"',
        ]);
      }
      if (Platform.isWindows) {
        return Process.runSync('powershell', [
          '-NoProfile',
          '-Command',
          '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null; '
              '[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("sudoer-pilot").Show('
              '[Windows.UI.Notifications.ToastNotification]::new('
              '[Windows.Data.Xml.Dom.XmlDocument]::new()))',
        ]);
      }
      return Process.runSync('notify-send', [title, message]);
    }();
    return result.exitCode == 0;
    } on Object {
      // A missing notifier binary is the absence of a notifier (C3): a
      // recoverable observation, never a thrown failure.
      return false;
    }
  }
}
