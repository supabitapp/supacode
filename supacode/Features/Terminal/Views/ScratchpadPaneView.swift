import AppKit
import SwiftUI

/// Full-pane plain-text editor rendered for `.scratchpad` tabs in place of the
/// terminal split tree. Text lives in `WorktreeTerminalState.scratchpadContents`
/// so it rides the layout snapshot across restarts.
struct ScratchpadPaneView: View {
  let tabId: TerminalTabID
  let terminalState: WorktreeTerminalState

  var body: some View {
    ScratchpadTextEditor(
      text: terminalState.scratchpadText(for: tabId),
      onTextChange: { terminalState.setScratchpadText($0, for: tabId) }
    )
  }
}

/// `NSTextView` wrapper mirroring the settings `PlainTextEditor`, plus undo,
/// find bar, and first-responder claim on appear. AppKit provides the rest of
/// the standard text OS features (copy/paste, dictation, spelling, services).
private struct ScratchpadTextEditor: NSViewRepresentable {
  let text: String
  let onTextChange: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onTextChange: onTextChange)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = NSTextView(frame: .zero)
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.font = Self.editorFont
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.string = text

    let scrollView = NSScrollView(frame: .zero)
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    Self.claimFocusWhenAppropriate(textView)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    context.coordinator.onTextChange = onTextChange
    guard let textView = nsView.documentView as? NSTextView else { return }
    // External mutation only (snapshot restore); typing round-trips equal.
    if textView.string != text {
      textView.string = text
    }
  }

  /// Monospaced at the Dynamic Type body size, matching the terminal-adjacent
  /// context (pasted logs, diffs, snippets align).
  private static var editorFont: NSFont {
    NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
  }

  /// Claim first responder once the view lands in a window, mirroring
  /// `WorktreeTerminalTabsView.shouldAutoFocusTerminal`: never steal focus from
  /// the sidebar's list views.
  private static func claimFocusWhenAppropriate(_ textView: NSTextView) {
    DispatchQueue.main.async {
      guard let window = textView.window else { return }
      let responder = window.firstResponder
      if responder is NSTableView || responder is NSOutlineView { return }
      window.makeFirstResponder(textView)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var onTextChange: (String) -> Void

    init(onTextChange: @escaping (String) -> Void) {
      self.onTextChange = onTextChange
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      onTextChange(textView.string)
    }
  }
}
