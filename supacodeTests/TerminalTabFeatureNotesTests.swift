import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct TerminalTabFeatureNotesTests {
  @Test func notesOpenToggledFlipsFlag() async {
    let tabID = TerminalTabID(rawValue: UUID())
    let store = TestStore(
      initialState: TerminalTabFeature.State(id: tabID, worktreeID: "/tmp/repo")
    ) {
      TerminalTabFeature()
    }

    await store.send(.notesOpenToggled) { $0.isNotesOpen = true }
    await store.send(.notesOpenToggled) { $0.isNotesOpen = false }
  }
}
