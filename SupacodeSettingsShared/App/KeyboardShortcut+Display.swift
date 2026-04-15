import SwiftUI

public extension KeyboardShortcut {
  var displaySymbols: [String] {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    parts.append(key.display)
    return parts
  }

  var display: String {
    displaySymbols.joined()
  }
}

public extension KeyEquivalent {
  var display: String {
    switch self {
    case .delete: "⌫"
    case .return: "↩"
    case .escape: "⎋"
    case .tab: "⇥"
    case .space: "Space"
    case .upArrow: "↑"
    case .downArrow: "↓"
    case .leftArrow: "←"
    case .rightArrow: "→"
    case .home: "↖"
    case .end: "↘"
    case .pageUp: "⇞"
    case .pageDown: "⇟"
    default: AppShortcutOverride.displayCharacter(for: self)
    }
  }
}
