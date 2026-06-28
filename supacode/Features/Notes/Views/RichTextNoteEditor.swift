import AppKit
import SwiftUI

/// `NSViewRepresentable` rich-text editor backing the notes panel. Clone of
/// `PlainTextEditor` with `isRichText = true`. Data flows one way: the seed is
/// applied once in `makeNSView` and the panel is rebuilt per tab via `.id(tabID)`,
/// so edits are reported out through `onChange` and never pushed back in. Each
/// instance owns its own `UndoManager`, giving per-(worktree, tab) undo isolation.
struct RichTextNoteEditor: NSViewRepresentable {
  let initialContent: NSAttributedString
  let controller: NoteEditorController
  let onChange: @MainActor (NSAttributedString) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(controller: controller, onChange: onChange)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = NSTextView(frame: .zero)
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isRichText = true
    textView.allowsUndo = true
    textView.importsGraphics = false
    textView.usesFontPanel = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.textContainerInset = NSSize(width: 6, height: 8)
    textView.font = NoteTextStyle.body.baseFont
    textView.typingAttributes = [
      .font: NoteTextStyle.body.baseFont,
      .foregroundColor: NSColor.labelColor,
    ]
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    if initialContent.length > 0 {
      textView.textStorage?.setAttributedString(initialContent)
    }
    controller.attach(textView)

    let scrollView = NSScrollView(frame: .zero)
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    // One-way flow: the seed is applied once in `makeNSView` and the view is
    // rebuilt per tab via `.id(tabID)`, so there's nothing to push back in.
    // Keep the change callback fresh for the current store binding.
    context.coordinator.onChange = onChange
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let controller: NoteEditorController
    var onChange: @MainActor (NSAttributedString) -> Void
    private let scopedUndoManager = UndoManager()

    init(controller: NoteEditorController, onChange: @escaping @MainActor (NSAttributedString) -> Void) {
      self.controller = controller
      self.onChange = onChange
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let attributed = textView.attributedString()
      MainActor.assumeIsolated { onChange(attributed) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      MainActor.assumeIsolated { controller.refreshActiveState() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      scopedUndoManager
    }
  }
}
