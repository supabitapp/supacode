import AppKit
import Carbon.HIToolbox
import Dependencies
import DependenciesTestSupport
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

struct CommandKeyObserverTests {
  @Test func shouldShowShortcutsForCommandOrControl() {
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.command]))
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.control]))
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.command, .shift]))
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.control, .option]))
  }

  @Test func shouldNotShowShortcutsForOtherModifiers() {
    #expect(CommandKeyObserver.shouldShowShortcuts(for: []) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.shift]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.option]) == false)
    #expect(CommandKeyObserver.shouldShowShortcuts(for: [.shift, .option]) == false)
  }

  @MainActor
  @Test(.dependencies) func tabSelectionHintsFollowTheConfiguredOverride() {
    withDependencies {
      $0.settingsFileStorage = SettingsTestStorage().storage
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-hints-\(UUID().uuidString).json")
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock {
        $0.global.shortcutOverrides = [
          .selectTab(1): AppShortcutOverride(keyCode: UInt16(kVK_ANSI_1), modifiers: .control),
          .selectTab(2): .disabled,
        ]
      }

      let observer = CommandKeyObserver()

      #expect(observer.tabSelectionHint(atSlot: 0) == "⌃1")
      #expect(observer.tabSelectionHint(atSlot: 1) == nil)
      #expect(observer.tabSelectionHint(atSlot: 2) == "⌘3")
      // The tab bar reads a slot per open tab, so a tenth tab must not index past the family.
      #expect(observer.tabSelectionHint(atSlot: 9) == nil)
      #expect(observer.tabSelectionHint(atSlot: -1) == nil)
    }
  }
}
