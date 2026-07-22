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
      cards: .init(
        agent: .updatesAvailable([.claude]),
        menuBarOnboarding: .visible,
        remoteRepositoriesBeta: .visible,
        terminalPersistence: .visible,
        highlight: .visible,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .agent(.updatesAvailable([.claude])))
  }

  @Test func agentPromptWinsOverEverything() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .promptInstall,
        menuBarOnboarding: .visible,
        remoteRepositoriesBeta: .visible,
        terminalPersistence: .visible,
        highlight: .visible,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func menuBarOnboardingWinsOverOlderCards() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        menuBarOnboarding: .visible,
        remoteRepositoriesBeta: .visible,
        terminalPersistence: .visible,
        highlight: .visible,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .menuBarOnboarding)
  }

  @Test func remoteRepositoriesBetaWinsOverOlderOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        menuBarOnboarding: .hidden,
        remoteRepositoriesBeta: .visible,
        terminalPersistence: .visible,
        highlight: .visible,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .remoteRepositoriesBeta)
  }

  @Test func terminalPersistenceWinsOverHighlightAndNested() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        menuBarOnboarding: .hidden,
        remoteRepositoriesBeta: .hidden,
        terminalPersistence: .visible,
        highlight: .visible,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .terminalPersistenceOnboarding)
  }

  @Test func highlightWinsOverNestedOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        menuBarOnboarding: .hidden,
        remoteRepositoriesBeta: .hidden,
        terminalPersistence: .hidden,
        highlight: .visible,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .highlightRelevantOnboarding)
  }

  @Test func nestedOnboardingShowsWhenHigherPriorityDismissed() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        menuBarOnboarding: .hidden,
        remoteRepositoriesBeta: .hidden,
        terminalPersistence: .hidden,
        highlight: .hidden,
        nestedOnboarding: .visible
      )
    )
    #expect(resolved == .nestedWorktreesOnboarding)
  }

  @Test func noneWhenAllHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      cards: .init(
        agent: .hidden,
        menuBarOnboarding: .hidden,
        remoteRepositoriesBeta: .hidden,
        terminalPersistence: .hidden,
        highlight: .hidden,
        nestedOnboarding: .hidden
      )
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

  @Test func menuBarOnboardingTransitionTokenIsStable() {
    #expect(SidebarBottomCardView.Slot.menuBarOnboarding.transitionToken == "menuBarOnboarding:visible")
  }

  @Test func menuBarCardVisibleWhenMenuBarShownAndNotDismissed() {
    #expect(
      MenuBarOnboardingCardView.resolveMode(showsMenuBarIcon: true, dismissedAt: .distantPast) == .visible
    )
  }

  @Test func menuBarCardHiddenWhenMenuBarNotShown() {
    #expect(
      MenuBarOnboardingCardView.resolveMode(showsMenuBarIcon: false, dismissedAt: .distantPast) == .hidden
    )
  }

  @Test func menuBarCardHiddenWhenDismissedAfterRelevance() {
    let afterRelevance = MenuBarOnboardingCardView.cardRelevantSinceDate.addingTimeInterval(1)
    #expect(
      MenuBarOnboardingCardView.resolveMode(showsMenuBarIcon: true, dismissedAt: afterRelevance) == .hidden
    )
  }

  @Test func menuBarCardHiddenWhenDismissedAtRelevanceBoundary() {
    // The relevance date must be on-or-before the ship date so a dismiss on
    // release day stays sticky.
    let atBoundary = MenuBarOnboardingCardView.cardRelevantSinceDate
    #expect(
      MenuBarOnboardingCardView.resolveMode(showsMenuBarIcon: true, dismissedAt: atBoundary) == .hidden
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
