import AppKit
import Testing

@testable import tty7

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
}
