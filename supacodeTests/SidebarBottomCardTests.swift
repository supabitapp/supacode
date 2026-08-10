import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarBottomCardTests {
  @Test func gitEnvironmentErrorWinsOverEverything() {
    // Even the highest-priority card loses to a blocked-git error.
    let cards = SidebarBottomCardView.Slot.agent(.promptInstall)
    #expect(
      SidebarBottomCardView.Slot.resolve(gitEnvironmentError: .xcodeLicenseNotAccepted, cards: cards)
        == .gitEnvironmentError(.xcodeLicenseNotAccepted)
    )
  }

  @Test func resolvedCardPassesThroughWhenGitEnvironmentHealthy() {
    #expect(
      SidebarBottomCardView.Slot.resolve(gitEnvironmentError: nil, cards: .fileExplorerBeta)
        == .fileExplorerBeta
    )
  }

  @Test func gitEnvironmentErrorTransitionTokenIsStable() {
    #expect(
      SidebarBottomCardView.Slot.gitEnvironmentError(.xcodeLicenseNotAccepted).transitionToken
        == "gitEnvironmentError:xcodeLicenseNotAccepted"
    )
  }

  @Test func agentPromptWinsOverEverything() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .promptInstall,
        layoutModes: .visible,
        fileExplorerBeta: .visible
      )
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func layoutModesWinsOverOlderCards() {
    // Newest card: it pre-empts every announcement below the agent prompt.
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        layoutModes: .visible,
        fileExplorerBeta: .visible
      )
    )
    #expect(resolved == .layoutModes)
  }

  @Test func layoutModesTransitionTokenIsStable() {
    #expect(SidebarBottomCardView.Slot.layoutModes.transitionToken == "layoutModes:visible")
  }

  @Test func layoutModesVisibleWhenNotDismissed() {
    #expect(LayoutModesCardView.resolveMode(dismissedAt: .distantPast) == .visible)
  }

  @Test func layoutModesHiddenWhenDismissedAfterRelevance() {
    let afterRelevance = LayoutModesCardView.cardRelevantSinceDate.addingTimeInterval(1)
    #expect(LayoutModesCardView.resolveMode(dismissedAt: afterRelevance) == .hidden)
  }

  @Test func layoutModesHiddenWhenDismissedAtRelevanceBoundary() {
    // The relevance date must be on-or-before the ship date so a dismiss on
    // release day stays sticky.
    let atBoundary = LayoutModesCardView.cardRelevantSinceDate
    #expect(LayoutModesCardView.resolveMode(dismissedAt: atBoundary) == .hidden)
  }

  @Test func fileExplorerBetaShowsWhenNewerCardsDismissed() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        layoutModes: .hidden,
        fileExplorerBeta: .visible
      )
    )
    #expect(resolved == .fileExplorerBeta)
  }

  @Test func fileExplorerBetaTransitionTokenIsStable() {
    #expect(SidebarBottomCardView.Slot.fileExplorerBeta.transitionToken == "fileExplorerBeta:visible")
  }

  @Test func fileExplorerBetaVisibleWhenNotDismissed() {
    #expect(FileExplorerBetaCardView.resolveMode(dismissedAt: .distantPast) == .visible)
  }

  @Test func fileExplorerBetaHiddenWhenDismissedAfterRelevance() {
    let afterRelevance = FileExplorerBetaCardView.cardRelevantSinceDate.addingTimeInterval(1)
    #expect(FileExplorerBetaCardView.resolveMode(dismissedAt: afterRelevance) == .hidden)
  }

  @Test func fileExplorerBetaHiddenWhenDismissedAtRelevanceBoundary() {
    // The relevance date must be on-or-before the ship date so a dismiss on
    // release day stays sticky.
    let atBoundary = FileExplorerBetaCardView.cardRelevantSinceDate
    #expect(FileExplorerBetaCardView.resolveMode(dismissedAt: atBoundary) == .hidden)
  }

  @Test func noneWhenAllHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        layoutModes: .hidden,
        fileExplorerBeta: .hidden
      )
    )
    #expect(resolved == SidebarBottomCardView.Slot.none)
  }
}
