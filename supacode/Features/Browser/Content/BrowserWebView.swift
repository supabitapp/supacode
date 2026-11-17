import AppKit
import SupacodeSettingsShared
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
  private static let logger = SupaLogger("Browser")

  var onFocus: (() -> Void)?
  var onAttach: (() -> Void)?
  var onKeyCommand: ((BrowserKeyCommand) -> Void)?
  var holdsBrowserFocus: () -> Bool = { false }

  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    super.init(frame: frame, configuration: configuration)
    keepPageScriptsFromTakingKeyboardFocus()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    keepPageScriptsFromTakingKeyboardFocus()
  }

  nonisolated deinit {}

  private func keepPageScriptsFromTakingKeyboardFocus() {
    guard responds(to: NSSelectorFromString("_setShouldSuppressFirstResponderChanges:")) else {
      Self.logger.warning("This WebKit cannot stop page scripts from taking keyboard focus.")
      return
    }
    setValue(true, forKey: "shouldSuppressFirstResponderChanges")
  }

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
