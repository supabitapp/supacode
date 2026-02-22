import Carbon.HIToolbox
import SwiftUI

nonisolated struct AppShortcutOverride: Codable, Equatable, Sendable {
  var keyCode: UInt16
  var modifiers: ModifierFlags

  struct ModifierFlags: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int
    static let command = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
  }
}

extension AppShortcutOverride {
  init(from eventModifiers: SwiftUI.EventModifiers, keyCode: UInt16) {
    self.keyCode = keyCode
    var flags: ModifierFlags = []
    if eventModifiers.contains(.command) { flags.insert(.command) }
    if eventModifiers.contains(.option) { flags.insert(.option) }
    if eventModifiers.contains(.control) { flags.insert(.control) }
    if eventModifiers.contains(.shift) { flags.insert(.shift) }
    self.modifiers = flags
  }

  var eventModifiers: SwiftUI.EventModifiers {
    var result: SwiftUI.EventModifiers = []
    if modifiers.contains(.command) { result.insert(.command) }
    if modifiers.contains(.option) { result.insert(.option) }
    if modifiers.contains(.control) { result.insert(.control) }
    if modifiers.contains(.shift) { result.insert(.shift) }
    return result
  }

  var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [ghosttyKeyName(for: keyCode)]
    return parts.joined(separator: "+")
  }

  var displayString: String {
    let parts = displayModifierParts + [displayCharacter(for: keyCode)]
    return parts.joined()
  }

  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent(for: keyCode), modifiers: eventModifiers)
  }

  private var ghosttyModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("super") }
    return parts
  }

  private var displayModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    return parts
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func ghosttyKeyName(for code: UInt16) -> String {
    switch Int(code) {
    case kVK_ANSI_A: return "a"
    case kVK_ANSI_B: return "b"
    case kVK_ANSI_C: return "c"
    case kVK_ANSI_D: return "d"
    case kVK_ANSI_E: return "e"
    case kVK_ANSI_F: return "f"
    case kVK_ANSI_G: return "g"
    case kVK_ANSI_H: return "h"
    case kVK_ANSI_I: return "i"
    case kVK_ANSI_J: return "j"
    case kVK_ANSI_K: return "k"
    case kVK_ANSI_L: return "l"
    case kVK_ANSI_M: return "m"
    case kVK_ANSI_N: return "n"
    case kVK_ANSI_O: return "o"
    case kVK_ANSI_P: return "p"
    case kVK_ANSI_Q: return "q"
    case kVK_ANSI_R: return "r"
    case kVK_ANSI_S: return "s"
    case kVK_ANSI_T: return "t"
    case kVK_ANSI_U: return "u"
    case kVK_ANSI_V: return "v"
    case kVK_ANSI_W: return "w"
    case kVK_ANSI_X: return "x"
    case kVK_ANSI_Y: return "y"
    case kVK_ANSI_Z: return "z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_LeftBracket: return "left_bracket"
    case kVK_ANSI_RightBracket: return "right_bracket"
    case kVK_ANSI_Comma: return "comma"
    case kVK_ANSI_Period: return "period"
    case kVK_ANSI_Slash: return "slash"
    case kVK_ANSI_Semicolon: return "semicolon"
    case kVK_ANSI_Quote: return "apostrophe"
    case kVK_ANSI_Backslash: return "backslash"
    case kVK_ANSI_Minus: return "minus"
    case kVK_ANSI_Equal: return "equal"
    case kVK_LeftArrow: return "arrow_left"
    case kVK_RightArrow: return "arrow_right"
    case kVK_UpArrow: return "arrow_up"
    case kVK_DownArrow: return "arrow_down"
    case kVK_Return: return "return"
    case kVK_Escape: return "escape"
    case kVK_Delete: return "backspace"
    case kVK_Tab: return "tab"
    case kVK_Space: return "space"
    default: return String(format: "0x%02x", code)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func displayCharacter(for code: UInt16) -> String {
    switch Int(code) {
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_Equal: return "="
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_Return: return "↩"
    case kVK_Escape: return "⎋"
    case kVK_Delete: return "⌫"
    case kVK_Tab: return "⇥"
    case kVK_Space: return "␠"
    default: return String(format: "0x%02x", code)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func keyEquivalent(for code: UInt16) -> KeyEquivalent {
    switch Int(code) {
    case kVK_ANSI_A: return KeyEquivalent("a")
    case kVK_ANSI_B: return KeyEquivalent("b")
    case kVK_ANSI_C: return KeyEquivalent("c")
    case kVK_ANSI_D: return KeyEquivalent("d")
    case kVK_ANSI_E: return KeyEquivalent("e")
    case kVK_ANSI_F: return KeyEquivalent("f")
    case kVK_ANSI_G: return KeyEquivalent("g")
    case kVK_ANSI_H: return KeyEquivalent("h")
    case kVK_ANSI_I: return KeyEquivalent("i")
    case kVK_ANSI_J: return KeyEquivalent("j")
    case kVK_ANSI_K: return KeyEquivalent("k")
    case kVK_ANSI_L: return KeyEquivalent("l")
    case kVK_ANSI_M: return KeyEquivalent("m")
    case kVK_ANSI_N: return KeyEquivalent("n")
    case kVK_ANSI_O: return KeyEquivalent("o")
    case kVK_ANSI_P: return KeyEquivalent("p")
    case kVK_ANSI_Q: return KeyEquivalent("q")
    case kVK_ANSI_R: return KeyEquivalent("r")
    case kVK_ANSI_S: return KeyEquivalent("s")
    case kVK_ANSI_T: return KeyEquivalent("t")
    case kVK_ANSI_U: return KeyEquivalent("u")
    case kVK_ANSI_V: return KeyEquivalent("v")
    case kVK_ANSI_W: return KeyEquivalent("w")
    case kVK_ANSI_X: return KeyEquivalent("x")
    case kVK_ANSI_Y: return KeyEquivalent("y")
    case kVK_ANSI_Z: return KeyEquivalent("z")
    case kVK_ANSI_0: return KeyEquivalent("0")
    case kVK_ANSI_1: return KeyEquivalent("1")
    case kVK_ANSI_2: return KeyEquivalent("2")
    case kVK_ANSI_3: return KeyEquivalent("3")
    case kVK_ANSI_4: return KeyEquivalent("4")
    case kVK_ANSI_5: return KeyEquivalent("5")
    case kVK_ANSI_6: return KeyEquivalent("6")
    case kVK_ANSI_7: return KeyEquivalent("7")
    case kVK_ANSI_8: return KeyEquivalent("8")
    case kVK_ANSI_9: return KeyEquivalent("9")
    case kVK_ANSI_LeftBracket: return KeyEquivalent("[")
    case kVK_ANSI_RightBracket: return KeyEquivalent("]")
    case kVK_ANSI_Comma: return KeyEquivalent(",")
    case kVK_ANSI_Period: return KeyEquivalent(".")
    case kVK_ANSI_Slash: return KeyEquivalent("/")
    case kVK_ANSI_Semicolon: return KeyEquivalent(";")
    case kVK_ANSI_Quote: return KeyEquivalent("'")
    case kVK_ANSI_Backslash: return KeyEquivalent("\\")
    case kVK_ANSI_Minus: return KeyEquivalent("-")
    case kVK_ANSI_Equal: return KeyEquivalent("=")
    case kVK_LeftArrow: return .leftArrow
    case kVK_RightArrow: return .rightArrow
    case kVK_UpArrow: return .upArrow
    case kVK_DownArrow: return .downArrow
    case kVK_Return: return .return
    case kVK_Escape: return .escape
    case kVK_Delete: return .delete
    case kVK_Tab: return .tab
    case kVK_Space: return .space
    default: return KeyEquivalent("?")
    }
  }
}
