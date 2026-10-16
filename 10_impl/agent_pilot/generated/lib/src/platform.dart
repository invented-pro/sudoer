/// C3/C6: the one place that knows the host platform.
///
/// The agent runs on Linux, macOS, and Windows. This module owns how the host
/// runs shell commands ([HostShell]) and how the interface toggles a raw
/// console (Windows only), so the tools (C3) and the interface (C6) stay
/// platform-neutral.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// C3/C8: how the host runs a shell command and reaps its process tree.
///
/// POSIX runs `/bin/sh -c`, wrapped in `setsid` when available so the command
/// leads its own process group — the group a timeout or cancel kills. Windows
/// runs `cmd.exe /c` and reaps the tree with `taskkill /T /F`. A custom
/// instance can be injected in tests; [host] is the running process's shell.
final class HostShell {
  HostShell({
    bool? windows,
    this.posixShell = '/bin/sh',
    this.commandInterpreter = 'cmd.exe',
  }) : isWindows = windows ?? Platform.isWindows;

  /// The host shell for the running process.
  static final HostShell host = HostShell();

  final bool isWindows;
  final String posixShell;
  final String commandInterpreter;

  /// Whether `setsid` is available; probed once on the first POSIX start.
  bool? _setsid;

  /// Start [command] in [workingDirectory]. The bool is whether the process
  /// leads a group that [killTree] can reap as a whole.
  Future<(Process, bool)> start(
      String command, String workingDirectory) async {
    if (isWindows) {
      final process = await Process.start(
        commandInterpreter,
        ['/c', command],
        workingDirectory: workingDirectory,
      );
      return (process, true);
    }
    if (posixShell == '/bin/sh' && _setsid != false) {
      try {
        final process = await Process.start(
          'setsid',
          [posixShell, '-c', command],
          workingDirectory: workingDirectory,
        );
        _setsid = true;
        return (process, true);
      } on ProcessException {
        _setsid = false;
      }
    }
    final process = await Process.start(
      posixShell,
      ['-c', command],
      workingDirectory: workingDirectory,
    );
    return (process, false);
  }

  /// Kill [process] and, when [grouped], its descendants (C8). Best-effort: a
  /// process that already exited is not an error.
  Future<void> killTree(Process process, bool grouped) async {
    if (isWindows) {
      try {
        await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
        return;
      } on ProcessException {
        // taskkill unavailable; fall through to the direct kill.
      }
    } else if (grouped &&
        Process.killPid(-process.pid, ProcessSignal.sigkill)) {
      return;
    }
    process.kill(ProcessSignal.sigkill);
  }
}

// Windows console input-mode flags (wincon.h) and the STD_INPUT_HANDLE id.
const int _enableProcessedInput = 0x0001;
const int _enableLineInput = 0x0002;
const int _enableEchoInput = 0x0004;
const int _enableMouseInput = 0x0010;
const int _enableQuickEditMode = 0x0040;
const int _enableExtendedFlags = 0x0080;
const int _enableVirtualTerminalInput = 0x0200;
const int _stdInputHandle = 0xFFFFFFF6; // (DWORD)-10

typedef _GetStdHandleC = IntPtr Function(Uint32);
typedef _GetStdHandleD = int Function(int);
typedef _GetConsoleModeC = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetConsoleModeD = int Function(int, Pointer<Uint32>);
typedef _SetConsoleModeC = Int32 Function(IntPtr, Uint32);
typedef _SetConsoleModeD = int Function(int, int);

int? _savedWindowsMode;

/// C6: put the Windows console input handle into raw virtual-terminal mode so
/// the human line editor receives arrow keys, Esc, and pastes as bytes. Dart's
/// `stdin.echoMode`/`lineMode` alone leave the legacy console, where those
/// events never reach the byte stream. No-op off Windows or without a console.
void enableWindowsRawInput() {
  if (!Platform.isWindows) return;
  final (getStdHandle, getConsoleMode, setConsoleMode) = _windowsConsole();
  final handle = getStdHandle(_stdInputHandle);
  final mode = calloc<Uint32>();
  try {
    if (getConsoleMode(handle, mode) == 0) return; // not a console
    _savedWindowsMode ??= mode.value;
    final next = (mode.value |
            _enableVirtualTerminalInput |
            _enableExtendedFlags |
            _enableMouseInput) &
        ~(_enableQuickEditMode |
            _enableLineInput |
            _enableEchoInput |
            _enableProcessedInput);
    setConsoleMode(handle, next);
  } finally {
    calloc.free(mode);
  }
}

/// C6: restore the console input mode saved by [enableWindowsRawInput].
void restoreWindowsRawInput() {
  if (!Platform.isWindows) return;
  final saved = _savedWindowsMode;
  if (saved == null) return;
  final (getStdHandle, _, setConsoleMode) = _windowsConsole();
  setConsoleMode(getStdHandle(_stdInputHandle), saved);
  _savedWindowsMode = null;
}

(_GetStdHandleD, _GetConsoleModeD, _SetConsoleModeD) _windowsConsole() {
  final k32 = DynamicLibrary.open('kernel32.dll');
  return (
    k32.lookupFunction<_GetStdHandleC, _GetStdHandleD>('GetStdHandle'),
    k32.lookupFunction<_GetConsoleModeC, _GetConsoleModeD>('GetConsoleMode'),
    k32.lookupFunction<_SetConsoleModeC, _SetConsoleModeD>('SetConsoleMode'),
  );
}
