import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppShortcutOverrideTests {
  @Test func encodeDecode() throws {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_LeftBracket),
      modifiers: [.command, .shift]
    )
    let data = try JSONEncoder().encode(override)
    let decoded = try JSONDecoder().decode(AppShortcutOverride.self, from: data)
    #expect(decoded == override)
  }

  @Test func carbonModifierFlagsMapsEachModifier() {
    #expect(AppShortcutOverride(keyCode: 0, modifiers: []).carbonModifierFlags == 0)
    #expect(AppShortcutOverride(keyCode: 0, modifiers: .command).carbonModifierFlags == UInt32(cmdKey))
    #expect(AppShortcutOverride(keyCode: 0, modifiers: .shift).carbonModifierFlags == UInt32(shiftKey))
    #expect(AppShortcutOverride(keyCode: 0, modifiers: .option).carbonModifierFlags == UInt32(optionKey))
    #expect(AppShortcutOverride(keyCode: 0, modifiers: .control).carbonModifierFlags == UInt32(controlKey))
  }

  @Test func carbonModifierFlagsCombinesAllCombinations() {
    let all: [AppShortcutOverride.ModifierFlags] = [.command, .shift, .option, .control]
    for raw in 0..<16 {
      var modifiers: AppShortcutOverride.ModifierFlags = []
      var expected: UInt32 = 0
      let carbon = [UInt32(cmdKey), UInt32(shiftKey), UInt32(optionKey), UInt32(controlKey)]
      for bit in 0..<4 where raw & (1 << bit) != 0 {
        modifiers.insert(all[bit])
        expected |= carbon[bit]
      }
      #expect(AppShortcutOverride(keyCode: 0, modifiers: modifiers).carbonModifierFlags == expected)
    }
  }

  @Test func symbolicHotkeyMaskDecodesNSEventModifiers() {
    // Real AppleSymbolicHotKeys mask values across single and combined modifiers.
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 0) == [])
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 262144) == .control)
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 524288) == .option)
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 131072) == .shift)
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 1_048_576) == .command)
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 786432) == [.control, .option])
    #expect(AppShortcutOverride.modifierFlags(fromSymbolicHotkeyMask: 1_179_648) == [.command, .shift])
  }

  @Test func ghosttyKeybindUsesLayoutCharacter() {
    let code = UInt16(kVK_ANSI_LeftBracket)
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command])
    let char = AppShortcutOverride.layoutCharacter(for: code)!.lowercased()
    #expect(override.ghosttyKeybind == "super+\(char)")
  }

  @Test func ghosttyKeybindLetterWithMultipleModifiers() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift])
    let char = AppShortcutOverride.layoutCharacter(for: UInt16(kVK_ANSI_A))!.lowercased()
    #expect(override.ghosttyKeybind == "shift+super+\(char)")
  }

  @Test func ghosttyKeybindArrowKey() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_UpArrow), modifiers: [.command, .control])
    #expect(override.ghosttyKeybind == "ctrl+super+arrow_up")
  }

  @Test func displayStringUsesLayoutCharacter() {
    let code = UInt16(kVK_ANSI_LeftBracket)
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command])
    let char = AppShortcutOverride.layoutCharacter(for: code)!.uppercased()
    #expect(override.displayString == "⌘\(char)")
  }

  @Test func displayStringLetterWithCommandShift() {
    let code = UInt16(kVK_ANSI_A)
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command, .shift])
    let char = AppShortcutOverride.layoutCharacter(for: code)!.uppercased()
    #expect(override.displayString == "⌘⇧\(char)")
  }

  @Test func displayStringArrowKey() {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_UpArrow), modifiers: [.command, .control])
    #expect(override.displayString == "⌘⌃↑")
  }

  @Test func keyboardShortcutConversion() {
    let code = UInt16(kVK_ANSI_LeftBracket)
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command])
    let shortcut = override.keyboardShortcut
    let char = AppShortcutOverride.layoutCharacter(for: code)!
    #expect(shortcut.key == KeyEquivalent(Character(char)))
    #expect(shortcut.modifiers == .command)
  }

  @Test func modifierFlagsCombining() {
    let flags: AppShortcutOverride.ModifierFlags = [.command, .shift]
    #expect(flags.contains(.command))
    #expect(flags.contains(.shift))
    #expect(!flags.contains(.option))
    #expect(!flags.contains(.control))
  }

  @Test func modifierFlagsEmpty() {
    let flags: AppShortcutOverride.ModifierFlags = []
    #expect(!flags.contains(.command))
    #expect(!flags.contains(.shift))
    #expect(!flags.contains(.option))
    #expect(!flags.contains(.control))
  }

  @Test func eventModifiersConversion() {
    let override = AppShortcutOverride(
      from: [.command, .shift],
      keyCode: UInt16(kVK_ANSI_N)
    )
    #expect(override.modifiers.contains(.command))
    #expect(override.modifiers.contains(.shift))
    #expect(!override.modifiers.contains(.option))
    #expect(!override.modifiers.contains(.control))
    #expect(override.eventModifiers == [.command, .shift])
  }

  @Test func eventModifiersConversionWithOptionAndControl() {
    let override = AppShortcutOverride(
      from: [.option, .control],
      keyCode: UInt16(kVK_ANSI_A)
    )
    #expect(override.modifiers.contains(.option))
    #expect(override.modifiers.contains(.control))
    #expect(!override.modifiers.contains(.command))
    #expect(!override.modifiers.contains(.shift))
    #expect(override.eventModifiers == [.option, .control])
  }

  @Test func eventModifiersRoundTrip() {
    let original: SwiftUI.EventModifiers = [.command, .shift, .option, .control]
    let override = AppShortcutOverride(from: original, keyCode: UInt16(kVK_ANSI_A))
    #expect(override.eventModifiers == original)
  }

  @Test func reverseLookupPrefersMenuKeyForShiftedCharacter() {
    let resolved = AppShortcutOverride.keyCode(
      forDisplayedKeyEquivalent: "\"",
      candidateKeyCodes: [19, 20],
      translatedCharacter: { code, modifierState in
        switch (code, modifierState) {
        case (19, 0): "e"
        case (19, 0x02): "2"
        case (20, 0): "%"
        case (20, 0x02): "\""
        default: nil
        }
      }
    )

    #expect(resolved == 20)
  }

  @Test func reverseLookupReturnsNilWhenNoMatch() {
    let resolved = AppShortcutOverride.keyCode(
      forDisplayedKeyEquivalent: "€",
      candidateKeyCodes: [19, 20],
      translatedCharacter: { code, modifierState in
        switch (code, modifierState) {
        case (19, 0): "e"
        case (19, 0x02): "E"
        case (20, 0): "3"
        case (20, 0x02): "#"
        default: nil
        }
      }
    )

    #expect(resolved == nil)
  }

  @Test func reverseLookupPrefersUnshiftedOverShifted() {
    // "2" is unshifted on key 21 and shifted on key 19. Unshifted should win.
    let resolved = AppShortcutOverride.keyCode(
      forDisplayedKeyEquivalent: "2",
      candidateKeyCodes: [19, 21],
      modifierStates: [0, 0x02],
      translatedCharacter: { code, modifierState in
        switch (code, modifierState) {
        case (19, 0): "é"
        case (19, 0x02): "2"
        case (21, 0): "2"
        case (21, 0x02): "\""
        default: nil
        }
      }
    )

    #expect(resolved == 21)
  }

  @Test func reverseLookupFindsOptionLayerCharacter() {
    let resolved = AppShortcutOverride.keyCode(
      forDisplayedKeyEquivalent: "€",
      candidateKeyCodes: [19, 20],
      modifierStates: [0, 0x02, 0x08, 0x0A],
      translatedCharacter: { code, modifierState in
        switch (code, modifierState) {
        case (19, 0): "e"
        case (19, 0x02): "E"
        case (19, 0x08): "€"
        case (20, 0): "3"
        case (20, 0x02): "#"
        default: nil
        }
      }
    )

    #expect(resolved == 19)
  }

  @Test func reverseLookupIsCaseInsensitive() {
    let resolved = AppShortcutOverride.keyCode(
      forDisplayedKeyEquivalent: "A",
      candidateKeyCodes: [0],
      translatedCharacter: { code, modifierState in
        switch (code, modifierState) {
        case (0, 0): "a"
        default: nil
        }
      }
    )

    #expect(resolved == 0)
  }

  // MARK: - Disabled sentinel.

  @Test func disabledSentinel() {
    let disabled = AppShortcutOverride.disabled
    #expect(disabled.keyCode == 0)
    #expect(disabled.modifiers == [])
    #expect(disabled.isEnabled == false)
  }

  // MARK: - Coding with isEnabled.

  @Test func encodeDecodeWithIsEnabledFalse() throws {
    let override = AppShortcutOverride(
      keyCode: UInt16(kVK_ANSI_K),
      modifiers: [.command],
      isEnabled: false
    )
    let data = try JSONEncoder().encode(override)
    let decoded = try JSONDecoder().decode(AppShortcutOverride.self, from: data)
    #expect(decoded == override)
    #expect(decoded.isEnabled == false)
  }

  // MARK: - Special key display strings.

  @Test func displayStringSpecialKeys() {
    let cases: [(Int, String)] = [
      (kVK_Return, "↩"),
      (kVK_Escape, "⎋"),
      (kVK_Delete, "⌫"),
      (kVK_Tab, "⇥"),
      (kVK_Space, "Space"),
      (kVK_LeftArrow, "←"),
      (kVK_RightArrow, "→"),
      (kVK_DownArrow, "↓"),
    ]
    for (code, expected) in cases {
      let override = AppShortcutOverride(keyCode: UInt16(code), modifiers: [.command])
      #expect(override.displayString == "⌘\(expected)")
    }
  }

  // MARK: - Special key ghostty keybinds.

  @Test func ghosttyKeybindSpecialKeys() {
    let cases: [(Int, String)] = [
      (kVK_Return, "enter"),
      (kVK_Escape, "escape"),
      (kVK_Delete, "backspace"),
      (kVK_Tab, "tab"),
      (kVK_Space, "space"),
      (kVK_LeftArrow, "arrow_left"),
      (kVK_RightArrow, "arrow_right"),
      (kVK_DownArrow, "arrow_down"),
    ]
    for (code, expected) in cases {
      let override = AppShortcutOverride(keyCode: UInt16(code), modifiers: [.command])
      #expect(override.ghosttyKeybind == "super+\(expected)")
    }
  }

  // MARK: - All four modifiers.

  @Test func displayStringAllModifiers() {
    let code = UInt16(kVK_ANSI_A)
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command, .shift, .option, .control])
    let char = AppShortcutOverride.displayCharacter(for: code)
    #expect(override.displayString == "⌘⇧⌥⌃\(char)")
  }

  // The key legend is the base cap character, not the option-transformed dead key
  // (⌥N is "⌥N", never "⌥˜").
  @Test func displayStringUsesBaseLegendIgnoringOption() {
    let code = UInt16(kVK_ANSI_N)
    let base = AppShortcutOverride.layoutCharacter(for: code)!.uppercased()
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command, .option])
    #expect(override.displayString == "⌘⌥\(base)")
  }

  @Test func ghosttyKeybindAllModifiers() {
    let code = UInt16(kVK_ANSI_A)
    let override = AppShortcutOverride(keyCode: code, modifiers: [.command, .shift, .option, .control])
    let char = AppShortcutOverride.layoutCharacter(for: code)!.lowercased()
    #expect(override.ghosttyKeybind == "ctrl+alt+shift+super+\(char)")
  }

  // MARK: - Reverse key code lookup.

  @Test func keyCodeForCharacterRoundTrips() {
    let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
    for letter in letters {
      let code = AppShortcutOverride.keyCode(for: letter)
      #expect(code != nil, "Expected key code for '\(letter)'")
      if let code {
        let resolved = AppShortcutOverride.layoutCharacter(for: code)
        #expect(resolved?.lowercased() == String(letter))
      }
    }
  }

  @Test func keyCodeForUnknownCharacterReturnsNil() {
    #expect(AppShortcutOverride.keyCode(for: "😀") == nil)
  }

  // MARK: - Hashing.

  @Test func differentIsEnabledProducesDifferentHash() {
    let enabled = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command], isEnabled: true)
    let disabled = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command], isEnabled: false)
    #expect(enabled != disabled)
    #expect(enabled.hashValue != disabled.hashValue)
  }

}
