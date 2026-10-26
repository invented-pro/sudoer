import 'package:dart_tui/dart_tui.dart'
    show
        Cmd,
        KeyCode,
        KeyMsg,
        Model,
        Msg,
        OutcomeModel,
        PasteMsg,
        Program,
        ProgramOption,
        QuitMsg,
        View,
        WindowSizeMsg,
        withAltScreen,
        withInput;

import 'tui_popup.dart';

/// C6: a one-shot, full-screen picker page for pre-session prompts — the
/// setup wizard's provider and model choosers. It reuses [TuiPopup], so the
/// interaction is the same non-modal surface as the TUI's popups: type to
/// filter and move at the same time (no filter/navigation mode split, so
/// backspace never strands the keyboard), Enter confirms, Esc cancels. The
/// list is sized from the terminal (`height - 8`, capped like the TUI's
/// popups) instead of a fixed 10-row window.
///
/// [stdinStream] is the process's shared stdin view (see `runProviderSetup`);
/// when null, dart_tui subscribes stdin itself, which is only safe when the
/// process exits after the page (a standalone `--setup`).
Future<String?> runPickPage({
  required String title,
  required List<TuiPopupItem> items,
  String? footer,
  Stream<List<int>>? stdinStream,
}) {
  if (items.isEmpty) return Future.value(null);
  return Program(options: _pageOptions(stdinStream)).runForResult(
    PickPageModel(TuiPopup(title: title, items: items, footer: footer)),
  );
}

List<ProgramOption> _pageOptions(Stream<List<int>>? stdinStream) => [
  withAltScreen(),
  if (stdinStream != null) withInput(stdinStream),
];

/// The [Model] behind [runPickPage], public so the gesture map is testable
/// headlessly (the same seam the TUI's popups are tested through).
final class PickPageModel extends Model implements OutcomeModel<String> {
  PickPageModel(this.page, {this.width = 80, this.height = 24, this.result});

  final TuiPopup page;

  /// Terminal size from the last [WindowSizeMsg]; sane defaults until one
  /// arrives (Program emits it before the first frame).
  final int width;
  final int height;

  final String? result;

  @override
  String? get outcome => result;

  (Model, Cmd?) _close(String? value) => (
    PickPageModel(page, width: width, height: height, result: value),
    () => QuitMsg(),
  );

  @override
  (Model, Cmd?) update(Msg msg) {
    switch (msg) {
      case WindowSizeMsg(:final width, :final height):
        // The same sizing rule as the TUI's popups: most of the screen,
        // with room for the box chrome and a margin.
        page.maxRows = (height - 8).clamp(3, 40);
        return (
          PickPageModel(page, width: width, height: height, result: result),
          null,
        );
      case PasteMsg(:final content):
        // The filter is token-based; keep a paste on one line so it narrows
        // instead of matching nothing.
        page.type(content.replaceAll(RegExp(r'[\r\n]+'), ' '));
        return (this, null);
      case KeyMsg():
        // The gesture map mirrors the TUI's popups (`_handlePopupKey`), so
        // the wizard and the session feel like one product.
        final key = msg.keyEvent;
        switch (key.keystroke()) {
          case 'esc':
          case 'ctrl+c':
            return _close(null);
          case 'enter':
          case 'ctrl+j':
            return _close(page.confirm());
          case 'up':
            page.move(-1);
          case 'down':
            page.move(1);
          case 'pgup':
            page.page(-1);
          case 'pgdown':
            page.page(1);
          case 'home':
            page.toTop();
          case 'end':
            page.toBottom();
          case 'backspace':
            page.backspace();
          case 'space':
            page.type(' ');
          default:
            if (key.code == KeyCode.rune && key.text.isNotEmpty) {
              page.type(key.text);
            }
        }
        return (this, null);
      default:
        return (this, null);
    }
  }

  @override
  View view() {
    // A blank frame the size of the screen; the popup centers itself in it.
    final frame = List.filled(height, '').join('\n');
    final drawn = page.overlay(frame, width: width, height: height);
    return View(content: drawn.content, cursor: drawn.cursor);
  }
}
