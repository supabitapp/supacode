import Carbon.HIToolbox
import SwiftUI

// Persisted override for an app shortcut binding.
public nonisolated struct AppShortcutOverride: Codable, Equatable, Hashable, Sendable {
  public var keyCode: UInt16
  public var modifiers: ModifierFlags
  public var isEnabled: Bool

  public struct ModifierFlags: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int
    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }

  public init(keyCode: UInt16, modifiers: ModifierFlags, isEnabled: Bool = true) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.isEnabled = isEnabled
  }

  // Sentinel for a disabled shortcut.
  public static let disabled = AppShortcutOverride(keyCode: 0, modifiers: [], isEnabled: false)

}

// MARK: - SwiftUI conversions.

public extension AppShortcutOverride {
  init(from eventModifiers: SwiftUI.EventModifiers, keyCode: UInt16) {
    self.keyCode = keyCode
    var flags: ModifierFlags = []
    if eventModifiers.contains(.command) { flags.insert(.command) }
    if eventModifiers.contains(.option) { flags.insert(.option) }
    if eventModifiers.contains(.control) { flags.insert(.control) }
    if eventModifiers.contains(.shift) { flags.insert(.shift) }
    self.modifiers = flags
    self.isEnabled = true
  }

  var eventModifiers: SwiftUI.EventModifiers {
    var result: SwiftUI.EventModifiers = []
    if modifiers.contains(.command) { result.insert(.command) }
    if modifiers.contains(.option) { result.insert(.option) }
    if modifiers.contains(.control) { result.insert(.control) }
    if modifiers.contains(.shift) { result.insert(.shift) }
    return result
  }

  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
  }

  var keyEquivalent: KeyEquivalent {
    Self.keyEquivalent(for: keyCode)
  }
}

// MARK: - Display.

public extension AppShortcutOverride {
  var displayString: String {
    Self.displaySymbols(for: keyCode, modifiers: modifiers).joined()
  }

  // Ordered array of individual display symbols: one per modifier, followed by the key.
  var displaySymbols: [String] {
    Self.displaySymbols(for: keyCode, modifiers: modifiers)
  }

  static func displaySymbols(for keyCode: UInt16, modifiers: ModifierFlags) -> [String] {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    parts.append(displayCharacter(for: keyCode, modifiers: modifiers))
    return parts
  }
}

// MARK: - System hotkeys.

public extension AppShortcutOverride {
  // Well-known macOS app conventions always reserved by AppKit (not in the symbolic hotkeys plist).
  static let appKitReservedDisplayStrings: Set<String> = ["⌘Q", "⌘W", "⌘H", "⌘M"]

  // Reads macOS system symbolic hotkeys at runtime and returns their display strings,
  // combined with well-known AppKit reserved shortcuts.
  static func allReservedDisplayStrings() -> Set<String> {
    systemReservedDisplayStrings().union(appKitReservedDisplayStrings)
  }

  // Reads macOS system symbolic hotkeys at runtime and returns their display strings.
  static func systemReservedDisplayStrings() -> Set<String> {
    guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
      let hotkeys = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
    else {
      shortcutLogger.warning("Could not read system symbolic hotkeys; conflict detection will be incomplete.")
      return []
    }
    var result: Set<String> = []
    for (_, value) in hotkeys {
      guard let entry = value as? [String: Any],
        entry["enabled"] as? Bool == true,
        let params = (entry["value"] as? [String: Any])?["parameters"] as? [Any],
        params.count >= 3,
        let keyCode = params[1] as? Int,
        let modifierFlags = params[2] as? Int
      else {
        continue
      }
      // Carbon modifier flags: cmdKey=0x100, shiftKey=0x200, optionKey=0x800, controlKey=0x1000.
      var flags: ModifierFlags = []
      if modifierFlags & 0x100 != 0 { flags.insert(.command) }
      if modifierFlags & 0x200 != 0 { flags.insert(.shift) }
      if modifierFlags & 0x800 != 0 { flags.insert(.option) }
      if modifierFlags & 0x1000 != 0 { flags.insert(.control) }
      let override = AppShortcutOverride(keyCode: UInt16(keyCode), modifiers: flags)
      result.insert(override.displayString)
    }
    return result
  }
}

// MARK: - Ghostty keybind.

public extension AppShortcutOverride {
  var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [Self.ghosttyKeyName(for: keyCode)]
    return parts.joined(separator: "+")
  }

  private var ghosttyModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("super") }
    return parts
  }
}

// MARK: - Key code mappings.

private nonisolated let shortcutLogger = SupaLogger("Shortcuts")

public extension AppShortcutOverride {
  // Reverse lookup: given a US QWERTY character, return its key code.
  static func keyCode(for character: Character) -> UInt16? {
    reverseUSQwerty[character]
  }

  private static let reverseUSQwerty: [Character: UInt16] = {
    var map: [Character: UInt16] = [:]
    for (code, str) in usQwertyFallback {
      if let character = str.first { map[character] = code }
    }
    return map
  }()

  // Resolves the character for a key code using the current keyboard layout,
  // falling back to US QWERTY when the layout is unavailable (e.g., CI, sandboxed contexts).
  static func layoutCharacter(for code: UInt16) -> String? {
    if let char = currentLayoutCharacter(for: code, modifierState: 0) { return char }
    shortcutLogger.debug("Using US QWERTY fallback for key code \(code)")
    return usQwertyFallback[code]
  }

  static func displayCharacter(for keyEquivalent: KeyEquivalent) -> String {
    guard let code = keyCode(forDisplayedKeyEquivalent: keyEquivalent.character) else {
      return String(keyEquivalent.character).uppercased()
    }
    return displayCharacter(for: code)
  }

  // The Ghostty key name for a given key code (e.g. "a", "arrow_up", "return").
  static func resolvedGhosttyKeyName(for code: UInt16) -> String {
    ghosttyKeyName(for: code)
  }

  // Uses UCKeyTranslate to resolve the character from the active input source.
  private static func currentLayoutCharacter(for code: UInt16, modifierState: UInt32) -> String? {
    guard let layoutData = currentKeyboardLayoutData() else {
      return nil
    }
    guard let bytePtr = CFDataGetBytePtr(layoutData) else {
      shortcutLogger.warning("CFDataGetBytePtr returned nil for key code \(code)")
      return nil
    }
    return bytePtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboardLayout in
      var deadKeyState: UInt32 = 0
      var chars = [UniChar](repeating: 0, count: 4)
      var length = 0
      let status = UCKeyTranslate(
        keyboardLayout,
        code,
        UInt16(kUCKeyActionDisplay),
        modifierState,
        UInt32(LMGetKbdType()),
        UInt32(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        4,
        &length,
        &chars
      )
      guard status == noErr, length > 0 else {
        if status != noErr {
          shortcutLogger.warning("UCKeyTranslate returned status \(status) for key code \(code).")
        }
        return nil
      }
      let str = String(utf16CodeUnits: chars, count: length)
      // Only return printable, non-whitespace characters.
      guard let scalar = str.unicodeScalars.first, scalar.value > 0x20, scalar.value != 0x7F else {
        return nil
      }
      return str
    }
  }

  private static func currentKeyboardLayoutData() -> CFData? {
    let sources = currentKeyboardInputSources()
    for inputSource in sources {
      guard let layoutPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
        continue
      }

      let layoutValue = unsafeBitCast(layoutPtr, to: CFTypeRef.self)
      guard CFGetTypeID(layoutValue) == CFDataGetTypeID() else {
        shortcutLogger.warning("TIS property returned non-CFData keyboard layout data.")
        continue
      }

      return unsafeDowncast(layoutValue, to: CFData.self)
    }

    if !sources.isEmpty {
      shortcutLogger.debug("No keyboard layout data found in \(sources.count) input source(s).")
    }
    return nil
  }

  // Tries progressively broader input sources. Non-Latin input methods may not
  // expose layout data on the primary source, so we fall through to the layout
  // and ASCII-capable sources.
  private static func currentKeyboardInputSources() -> [TISInputSource] {
    var sources: [TISInputSource] = []
    if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
      sources.append(source)
    }
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() {
      sources.append(source)
    }
    if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
      sources.append(source)
    }
    if sources.isEmpty {
      shortcutLogger.warning("No keyboard input sources available; layout-aware display will use fallbacks.")
    }
    return sources
  }

  // AppKit renders menu key equivalents from the logical key equivalent. Reverse
  // lookup the active layout so our own labels match the menu bar.
  static func keyCode(
    forDisplayedKeyEquivalent character: Character,
    candidateKeyCodes: [UInt16] = candidatePrintableKeyCodes,
    modifierStates: [UInt32] = menuDisplayModifierStates,
    translatedCharacter: (UInt16, UInt32) -> String?
  ) -> UInt16? {
    let target = String(character).lowercased()
    for modifierState in modifierStates {
      for code in candidateKeyCodes {
        guard let resolved = translatedCharacter(code, modifierState) else {
          continue
        }
        guard resolved.lowercased() == target else { continue }
        return code
      }
    }
    return nil
  }

  static func keyCode(forDisplayedKeyEquivalent character: Character) -> UInt16? {
    keyCode(forDisplayedKeyEquivalent: character) { code, modifierState in
      currentLayoutCharacter(for: code, modifierState: modifierState)
    }
  }

  // US QWERTY character mapping for environments without a keyboard layout.
  private static let usQwertyFallback: [UInt16: String] = {
    let entries: [(Int, String)] = [
      (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"),
      (kVK_ANSI_E, "e"), (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"),
      (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"),
      (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"), (kVK_ANSI_P, "p"),
      (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
      (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"),
      (kVK_ANSI_Y, "y"), (kVK_ANSI_Z, "z"),
      (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
      (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
      (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
      (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
      (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
      (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Backslash, "\\"),
      (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_Grave, "`"),
    ]
    var map: [UInt16: String] = [:]
    for (code, char) in entries { map[UInt16(code)] = char }
    return map
  }()

  // UCKeyTranslate modifier states: unmodified, shift, option, shift+option.
  // Ordered so the simplest printable mapping is preferred during reverse lookup.
  static let menuDisplayModifierStates: [UInt32] = [0, 0x02, 0x08, 0x0A]
  static let candidatePrintableKeyCodes: [UInt16] = Array(usQwertyFallback.keys).sorted()

  private static func ghosttyKeyName(for code: UInt16) -> String {
    switch Int(code) {
    case kVK_LeftArrow: "arrow_left"
    case kVK_RightArrow: "arrow_right"
    case kVK_UpArrow: "arrow_up"
    case kVK_DownArrow: "arrow_down"
    case kVK_Return: "return"
    case kVK_Escape: "escape"
    case kVK_Delete: "backspace"
    case kVK_Tab: "tab"
    case kVK_Space: "space"
    default: layoutCharacter(for: code)?.lowercased() ?? String(format: "0x%02x", code)
    }
  }

  static func displayCharacter(for code: UInt16, modifiers: ModifierFlags = []) -> String {
    switch Int(code) {
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_Return: return "↩"
    case kVK_Escape: return "⎋"
    case kVK_Delete: return "⌫"
    case kVK_Tab: return "⇥"
    case kVK_Space: return "Space"
    default:
      let modifierState = displayModifierState(for: modifiers)
      if let character = currentLayoutCharacter(for: code, modifierState: modifierState) {
        return character.uppercased()
      }
      return layoutCharacter(for: code)?.uppercased() ?? String(format: "0x%02x", code)
    }
  }

  static func keyEquivalent(for code: UInt16) -> KeyEquivalent {
    switch Int(code) {
    case kVK_LeftArrow: return .leftArrow
    case kVK_RightArrow: return .rightArrow
    case kVK_UpArrow: return .upArrow
    case kVK_DownArrow: return .downArrow
    case kVK_Return: return .return
    case kVK_Escape: return .escape
    case kVK_Delete: return .delete
    case kVK_Tab: return .tab
    case kVK_Space: return .space
    default:
      guard let char = layoutCharacter(for: code)?.first else {
        shortcutLogger.warning("Cannot resolve KeyEquivalent for key code \(code), using fallback '?'.")
        return KeyEquivalent("?")
      }
      return KeyEquivalent(char)
    }
  }

  // Only shift and option affect the printed character; command and control
  // do not alter UCKeyTranslate output.
  private static func displayModifierState(for modifiers: ModifierFlags) -> UInt32 {
    var state: UInt32 = 0
    if modifiers.contains(.shift) { state |= 0x02 }
    if modifiers.contains(.option) { state |= 0x08 }
    return state
  }
}
