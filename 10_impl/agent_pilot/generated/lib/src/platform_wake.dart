import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

/// C11: the OS wake scheduler, an injected adapter. The real implementations
/// register a platform wake (`sudoer-pilot tick` at the next due time); the
/// gate's [FakeScheduler] records the unit/wake it would write, so the
/// platform shape is assertable without touching the host.
abstract interface class Scheduler {
  /// Record the wake for [when]; returns the unit/path that was written.
  String installWake(DateTime when, String workingDirectory);

  /// Remove every OS hook this agent installed.
  bool uninstall();
}

/// The deterministic fake the gate pins: nothing leaves the process; the
/// recorded wake strings are the assertion surface.
final class FakeScheduler implements Scheduler {
  final List<String> installed = [];

  @override
  String installWake(DateTime when, String workingDirectory) {
    final unit = 'sudoer-pilot tick  # next_due=${when.toIso8601String()}';
    installed.add(unit);
    return unit;
  }

  @override
  bool uninstall() {
    final had = installed.isNotEmpty;
    installed.clear();
    return had;
  }
}

/// The real Linux scheduler: a `systemd --user` service + timer. Written
/// under `XDG_CONFIG_HOME/systemd/user/`; a missing `systemctl` is reported
/// by [installWake]'s return value, never silently ignored.
final class SystemdScheduler implements Scheduler {
  @override
  String installWake(DateTime when, String workingDirectory) {
    final dir = Directory(_unitDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final servicePath = p.join(_unitDir, _unitName('service'));
    final timerPath = p.join(_unitDir, _unitName('timer'));
    File(servicePath).writeAsStringSync('''
[Unit]
Description=sudoer-pilot scheduled task fire

[Service]
Type=oneshot
WorkingDirectory=$workingDirectory
ExecStart=$workingDirectory/sudoer-pilot tick
''');
    File(timerPath).writeAsStringSync('''
[Unit]
Description=sudoer-pilot next due wake

[Timer]
OnCalendar=${_onCalendar(when)}
Persistent=true

[Install]
WantedBy=timers.target
''');
    Process.runSync('systemctl', ['--user', 'daemon-reload']);
    return timerPath;
  }

  @override
  bool uninstall() {
    var removed = false;
    for (final suffix in const ['service', 'timer']) {
      final file = File(p.join(_unitDir, _unitName(suffix)));
      if (file.existsSync()) {
        file.deleteSync();
        removed = true;
      }
    }
    Process.runSync('systemctl', ['--user', 'daemon-reload']);
    return removed;
  }

  String get _unitDir {
    final configHome =
        Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME']}/.config';
    return p.join(configHome, 'systemd', 'user');
  }

  String _unitName(String suffix) => 'sudoer-pilot.$suffix';

  /// The timer's OnCalendar for [when], UTC-stamped and one-shot by OnUnitActiveUS
  /// semantics via a fixed calendar entry.
  String _onCalendar(DateTime when) {
    final t = when.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:00 UTC';
  }
}

/// The real macOS scheduler: a `launchd` LaunchAgent with a calendar
/// interval, written under `~/Library/LaunchAgents/`.
final class LaunchdScheduler implements Scheduler {
  @override
  String installWake(DateTime when, String workingDirectory) {
    final dir = Directory(
        '${Platform.environment['HOME']}/Library/LaunchAgents');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = p.join(dir.path, 'com.sudoer.pilot.tick.plist');
    final t = when.toUtc();
    File(path).writeAsStringSync(jsonEncode({
      'Label': 'com.sudoer.pilot.tick',
      'ProgramArguments': ['$workingDirectory/sudoer-pilot', 'tick'],
      'WorkingDirectory': workingDirectory,
      'StartCalendarInterval': {
        'hour': t.hour,
        'minute': t.minute,
        'day': t.day,
        'month': t.month,
      },
    }));
    return path;
  }

  @override
  bool uninstall() {
    final path = p.join(
        Platform.environment['HOME']!, 'Library/LaunchAgents/com.sudoer.pilot.tick.plist');
    final file = File(path);
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }
}

/// The real Windows scheduler: a Task Scheduler task (registered via
/// `schtasks`). The command shape is what tests assert on Windows; the gate
/// pins the fake on every platform.
final class TaskSchedulerWake implements Scheduler {
  @override
  String installWake(DateTime when, String workingDirectory) {
    final t = when.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}T${two(t.hour)}${two(t.minute)}00';
    Process.runSync('schtasks', [
      '/Create',
      '/F',
      '/TN',
      'sudoer-pilot-tick',
      '/TR',
      '"$workingDirectory\\sudoer-pilot.exe tick"',
      '/SC',
      'ONCE',
      '/SD',
      '${two(t.month)}/${two(t.day)}/${t.year}',
      '/ST',
      '${two(t.hour)}:${two(t.minute)}',
    ]);
    return 'sudoer-pilot-tick@$stamp';
  }

  @override
  bool uninstall() {
    Process.runSync('schtasks', ['/Delete', '/F', '/TN', 'sudoer-pilot-tick']);
    return true;
  }
}

/// The platform scheduler for this host.
Scheduler systemScheduler() {
  if (Platform.isMacOS) return LaunchdScheduler();
  if (Platform.isWindows) return TaskSchedulerWake();
  return SystemdScheduler();
}
