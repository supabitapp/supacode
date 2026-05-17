import ComposableArchitecture
import Foundation
import Sharing
import Testing

@testable import supacode

/// Locks the state-driven auto-dismiss for the highlight onboarding card.
/// The dismiss lives in the reducer's `.sidebarGroupingTogglesChanged`
/// handler so any path that mutates the @Shared grouping toggles fires it,
/// not just the menu binding setter.
///
/// Each test scopes `defaultAppStorage = .inMemory` so the @Shared(.appStorage)
/// writes don't leak across the suite (a process-global UserDefaults write
/// would otherwise pollute later tests that read these keys).
@MainActor
struct SidebarGroupingDismissTests {
  @Test func togglesOffWithUndismissedCardSetsDismissedAtNow() async {
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    await withDependencies {
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(fixedDate)
    } operation: {
      @Shared(.sidebarGroupPinnedRows) var pinned
      @Shared(.sidebarGroupActiveRows) var active
      @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
      var dismissedAt: Date = .distantPast
      $pinned.withLock { $0 = false }
      $active.withLock { $0 = false }

      let store = TestStore(initialState: RepositoriesFeature.State()) {
        RepositoriesFeature()
      }
      await store.send(.sidebarGroupingTogglesChanged)

      #expect(dismissedAt == fixedDate)
    }
  }

  @Test func togglesOnLeavesDismissedAtUntouched() async {
    let originalDismissedAt = Date(timeIntervalSince1970: 1_700_000_000)
    await withDependencies {
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_800_000_000))
    } operation: {
      @Shared(.sidebarGroupPinnedRows) var pinned
      @Shared(.sidebarGroupActiveRows) var active
      @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
      var dismissedAt: Date = .distantPast
      $pinned.withLock { $0 = true }
      $active.withLock { $0 = false }
      $dismissedAt.withLock { $0 = originalDismissedAt }

      let store = TestStore(initialState: RepositoriesFeature.State()) {
        RepositoriesFeature()
      }
      await store.send(.sidebarGroupingTogglesChanged)

      #expect(dismissedAt == originalDismissedAt)
    }
  }

  @Test func alreadyDismissedDoesNotOverwriteTimestamp() async {
    let preexistingDismissedAt = HighlightRelevantOnboardingCardView.cardRelevantSinceDate
      .addingTimeInterval(60)
    await withDependencies {
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_900_000_000))
    } operation: {
      @Shared(.sidebarGroupPinnedRows) var pinned
      @Shared(.sidebarGroupActiveRows) var active
      @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
      var dismissedAt: Date = .distantPast
      $pinned.withLock { $0 = false }
      $active.withLock { $0 = false }
      $dismissedAt.withLock { $0 = preexistingDismissedAt }

      let store = TestStore(initialState: RepositoriesFeature.State()) {
        RepositoriesFeature()
      }
      await store.send(.sidebarGroupingTogglesChanged)

      // The dismiss timestamp is preserved instead of being bumped to `.now`,
      // so a user who already dismissed the card doesn't see its dismissed-at
      // walk forward on every toggle flip.
      #expect(dismissedAt == preexistingDismissedAt)
    }
  }
}
