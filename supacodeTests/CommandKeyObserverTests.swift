import AppKit
import Testing

@testable import supacode

struct CommandKeyObserverTests {
  @Test func detectsCommandModifierIndependently() {
    #expect(CommandKeyObserver.isCommandActive(for: [.command]))
    #expect(CommandKeyObserver.isCommandActive(for: [.command, .shift]))
    #expect(CommandKeyObserver.isCommandActive(for: [.control]) == false)
    #expect(CommandKeyObserver.isCommandActive(for: []) == false)
  }

  @Test func detectsControlModifierIndependently() {
    #expect(CommandKeyObserver.isControlActive(for: [.control]))
    #expect(CommandKeyObserver.isControlActive(for: [.control, .option]))
    #expect(CommandKeyObserver.isControlActive(for: [.command]) == false)
    #expect(CommandKeyObserver.isControlActive(for: []) == false)
  }
}
