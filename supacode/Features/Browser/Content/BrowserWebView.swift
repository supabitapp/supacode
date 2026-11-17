import AppKit
import WebKit

nonisolated enum BrowserKeyCommand: Equatable, Sendable {
  case focusAddress
  case reload
  case goBack
  case goForward
  case zoomIn
  case zoomOut
  case resetZoom

  init?(characters: String?, modifiers: NSEvent.ModifierFlags) {
    guard
      modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        == .command
    else { return nil }
    switch characters?.lowercased() {
    case "l": self = .focusAddress
    case "r": self = .reload
    case "[": self = .goBack
    case "]": self = .goForward
    case "=", "+": self = .zoomIn
    case "-": self = .zoomOut
    case "0": self = .resetZoom
    default: return nil
    }
  }

  init?(event: NSEvent) {
    guard event.type == .keyDown else { return nil }
    self.init(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
  }
}

final class BrowserWebView: WKWebView {
  var onFocus: (() -> Void)?
  var onAttach: (() -> Void)?
  var onKeyCommand: ((BrowserKeyCommand) -> Void)?
  var holdsBrowserFocus: () -> Bool = { false }

  nonisolated deinit {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    onAttach?()
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became {
      onFocus?()
    }
    return became
  }

  // AppKit offers a key equivalent to every view in the window, and WebKit
  // consumes it for the page before the menu sees it, so the app's own chords
  // are routed here first and only while this browser holds keyboard focus.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, holdsBrowserFocus() else {
      return super.performKeyEquivalent(with: event)
    }
    if let command = BrowserKeyCommand(event: event) {
      onKeyCommand?(command)
      return true
    }
    if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
