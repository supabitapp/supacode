import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarBottomCardTests {
  @Test func gitEnvironmentErrorWinsOverEverything() {
    // Even the highest-priority card loses to a blocked-git error.
    let cards = SidebarBottomCardView.Slot.agent(.updatesAvailable([.claude]))
    #expect(
      SidebarBottomCardView.Slot.resolve(gitEnvironmentError: .xcodeLicenseNotAccepted, cards: cards)
        == .gitEnvironmentError(.xcodeLicenseNotAccepted)
    )
  }

  @Test func resolvedCardPassesThroughWhenGitEnvironmentHealthy() {
    #expect(
      SidebarBottomCardView.Slot.resolve(gitEnvironmentError: nil, cards: .remoteRepositoriesBeta)
        == .remoteRepositoriesBeta
    )
  }

  @Test func gitEnvironmentErrorTransitionTokenIsStable() {
    #expect(
      SidebarBottomCardView.Slot.gitEnvironmentError(.xcodeLicenseNotAccepted).transitionToken
        == "gitEnvironmentError:xcodeLicenseNotAccepted"
    )
  }

  @Test func agentUpdatesWinOverEverything() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .updatesAvailable([.claude]),
      remoteRepositoriesBetaMode: .visible,
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.updatesAvailable([.claude])))
  }

  @Test func agentPromptWinsOverEverything() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .promptInstall,
      remoteRepositoriesBetaMode: .visible,
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func remoteRepositoriesBetaWinsOverOlderOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      remoteRepositoriesBetaMode: .visible,
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .remoteRepositoriesBeta)
  }

  @Test func terminalPersistenceWinsOverHighlightAndNested() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      remoteRepositoriesBetaMode: .hidden,
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .terminalPersistenceOnboarding)
  }

  @Test func highlightWinsOverNestedOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      remoteRepositoriesBetaMode: .hidden,
      terminalPersistenceMode: .hidden,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .highlightRelevantOnboarding)
  }

  @Test func nestedOnboardingShowsWhenHigherPriorityDismissed() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      remoteRepositoriesBetaMode: .hidden,
      terminalPersistenceMode: .hidden,
      highlightMode: .hidden,
      onboardingMode: .visible
    )
    #expect(resolved == .nestedWorktreesOnboarding)
  }

  @Test func noneWhenAllHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      remoteRepositoriesBetaMode: .hidden,
      terminalPersistenceMode: .hidden,
      highlightMode: .hidden,
      onboardingMode: .hidden
    )
    #expect(resolved == SidebarBottomCardView.Slot.none)
  }

  @Test func terminalPersistenceTransitionTokenIsStable() {
    #expect(
      SidebarBottomCardView.Slot.terminalPersistenceOnboarding.transitionToken == "terminalPersistence:visible"
    )
  }

  @Test func remoteRepositoriesBetaTransitionTokenIsStable() {
    #expect(
      SidebarBottomCardView.Slot.remoteRepositoriesBeta.transitionToken == "remoteRepositoriesBeta:visible"
    )
  }

  @Test func agentVariantStableAcrossSkillAgentOrder() {
    let lhs = SidebarBottomCardView.Slot.agent(.updatesAvailable([.claude, .codex])).transitionToken
    let rhs = SidebarBottomCardView.Slot.agent(.updatesAvailable([.codex, .claude])).transitionToken
    #expect(lhs == rhs)
  }

  @Test func onboardingTransitionTokenUsesNestedWorktreesPrefix() {
    #expect(SidebarBottomCardView.Slot.nestedWorktreesOnboarding.transitionToken == "nestedWorktrees:visible")
  }

  @Test func highlightOnboardingTransitionTokenIsStable() {
    #expect(
      SidebarBottomCardView.Slot.highlightRelevantOnboarding.transitionToken == "highlightRelevant:visible"
    )
  }

  @Test func highlightCardHiddenWhenBothTogglesOff() {
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: false,
        groupActiveRows: false,
        dismissedAt: .distantPast
      ) == .hidden
    )
  }

  @Test func highlightCardVisibleWhenOnlyPinnedOn() {
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: true,
        groupActiveRows: false,
        dismissedAt: .distantPast
      ) == .visible
    )
  }

  @Test func highlightCardVisibleWhenOnlyActiveOn() {
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: false,
        groupActiveRows: true,
        dismissedAt: .distantPast
      ) == .visible
    )
  }

  @Test func highlightCardHiddenWhenDismissedAfterRelevance() {
    let afterRelevance = HighlightRelevantOnboardingCardView.cardRelevantSinceDate.addingTimeInterval(1)
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: true,
        groupActiveRows: true,
        dismissedAt: afterRelevance
      ) == .hidden
    )
  }

  @Test func highlightCardHiddenWhenDismissedAtRelevanceBoundary() {
    // The relevance date must be on-or-before the ship date so a dismiss on
    // release day stays sticky. A future-dated relevance date would resurface
    // the card the next time SwiftUI re-rendered it.
    let atBoundary = HighlightRelevantOnboardingCardView.cardRelevantSinceDate
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: true,
        groupActiveRows: true,
        dismissedAt: atBoundary
      ) == .hidden
    )
  }
}
