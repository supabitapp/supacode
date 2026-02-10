import AppKit
import SwiftUI

struct DiffTextView: NSViewRepresentable {
  let revision: Int
  let text: String

  func makeNSView(context: Context) -> DiffTextContainerView {
    DiffTextContainerView()
  }

  func updateNSView(_ nsView: DiffTextContainerView, context: Context) {
    nsView.update(revision: revision, text: text)
  }
}

final class DiffTextContainerView: NSView {
  private let scrollView = NSScrollView()
  private let textView = NSTextView()
  private let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  private var lastRevision: Int?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  func update(revision: Int, text: String) {
    if lastRevision == revision { return }
    lastRevision = revision

    if text.isEmpty {
      textView.string = ""
      return
    }

    textView.textStorage?.setAttributedString(
      NSAttributedString(
        string: text,
        attributes: [
          .font: font,
          .foregroundColor: NSColor.labelColor,
        ]
      )
    )
  }

  private func setup() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.drawsBackground = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width, .height]
    textView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.documentView = textView
  }
}
