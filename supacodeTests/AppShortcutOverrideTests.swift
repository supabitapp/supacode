import Foundation
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct AppShortcutOverrideTests {
  @Test func encodeDecode() throws {
    let override = AppShortcutOverride(
      keyCode: 0x21,
      modifiers: [.command, .shift]
    )
    let data = try JSONEncoder().encode(override)
    let decoded = try JSONDecoder().decode(AppShortcutOverride.self, from: data)
    #expect(decoded == override)
  }

  @Test func ghosttyKeybindLeftBracketWithCommand() {
    let override = AppShortcutOverride(keyCode: 0x21, modifiers: [.command])
    #expect(override.ghosttyKeybind == "super+left_bracket")
  }

  @Test func ghosttyKeybindLetterWithMultipleModifiers() {
    let override = AppShortcutOverride(keyCode: 0x00, modifiers: [.command, .shift])
    #expect(override.ghosttyKeybind == "shift+super+a")
  }

  @Test func ghosttyKeybindArrowKey() {
    let override = AppShortcutOverride(keyCode: 0x7E, modifiers: [.command, .control])
    #expect(override.ghosttyKeybind == "ctrl+super+arrow_up")
  }

  @Test func ghosttyKeybindUnknownKeyCode() {
    let override = AppShortcutOverride(keyCode: 0xFF, modifiers: [])
    #expect(override.ghosttyKeybind == "0xff")
  }

  @Test func displayStringLeftBracketWithCommand() {
    let override = AppShortcutOverride(keyCode: 0x21, modifiers: [.command])
    #expect(override.displayString == "⌘[")
  }

  @Test func displayStringLetterWithCommandShift() {
    let override = AppShortcutOverride(keyCode: 0x00, modifiers: [.command, .shift])
    #expect(override.displayString == "⌘⇧A")
  }

  @Test func displayStringArrowKey() {
    let override = AppShortcutOverride(keyCode: 0x7E, modifiers: [.command, .control])
    #expect(override.displayString == "⌘⌃↑")
  }

  @Test func keyboardShortcutConversion() {
    let override = AppShortcutOverride(keyCode: 0x21, modifiers: [.command])
    let shortcut = override.keyboardShortcut
    #expect(shortcut.key == KeyEquivalent("["))
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

  @Test func eventModifiersRoundTrip() {
    let override = AppShortcutOverride(from: [.command, .shift], keyCode: 0x00)
    #expect(override.modifiers.contains(.command))
    #expect(override.modifiers.contains(.shift))
    #expect(!override.modifiers.contains(.option))
    #expect(override.eventModifiers.contains(.command))
    #expect(override.eventModifiers.contains(.shift))
  }

  @Test func globalSettingsDecodesWithoutShortcutOverrides() throws {
    let json = """
      {
        "appearanceMode": "dark",
        "updatesAutomaticallyCheckForUpdates": true,
        "updatesAutomaticallyDownloadUpdates": false
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.shortcutOverrides == [:])
  }

  @Test func globalSettingsDecodesWithShortcutOverrides() throws {
    let json = """
      {
        "appearanceMode": "dark",
        "updatesAutomaticallyCheckForUpdates": true,
        "updatesAutomaticallyDownloadUpdates": false,
        "shortcutOverrides": {
          "toggleLeftSidebar": {
            "keyCode": 33,
            "modifiers": 1
          }
        }
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.shortcutOverrides.count == 1)
    #expect(settings.shortcutOverrides["toggleLeftSidebar"]?.keyCode == 33)
    #expect(settings.shortcutOverrides["toggleLeftSidebar"]?.modifiers == .command)
  }
}
