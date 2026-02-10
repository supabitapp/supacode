import AppKit
import SwiftUI

struct DiffTextView: NSViewRepresentable {
  let attributedDiff: NSAttributedString?
  let scrollToFileOffset: Int?

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )

    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = context.coordinator.textView else { return }
    if let attributed = attributedDiff {
      if textView.textStorage?.string != attributed.string {
        textView.textStorage?.setAttributedString(attributed)
      }
    } else {
      textView.textStorage?.setAttributedString(NSAttributedString())
    }
    if let offset = scrollToFileOffset, offset >= 0,
      let storage = textView.textStorage, offset < storage.length
    {
      let range = NSRange(location: offset, length: 0)
      textView.scrollRangeToVisible(range)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var textView: NSTextView?
  }
}
