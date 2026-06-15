import Foundation
import Tty7SettingsShared
import Testing

@testable import tty7

@MainActor
struct SidebarBottomCardTests {
  @Test func agentUpdatesWinOverEverything() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .updatesAvailable([.claude]),
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.updatesAvailable([.claude])))
  }

  @Test func agentPromptWinsOverEverything() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .promptInstall,
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func terminalPersistenceWinsOverHighlightAndNested() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      terminalPersistenceMode: .visible,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .terminalPersistenceOnboarding)
  }

  @Test func highlightWinsOverNestedOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      terminalPersistenceMode: .hidden,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .highlightRelevantOnboarding)
  }

  @Test func nestedOnboardingShowsWhenHigherPriorityDismissed() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      terminalPersistenceMode: .hidden,
      highlightMode: .hidden,
      onboardingMode: .visible
    )
    #expect(resolved == .nestedWorktreesOnboarding)
  }

  @Test func noneWhenAllHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
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

  @Test func highlightCardHiddenWhenToggleOff() {
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: false,
        dismissedAt: .distantPast
      ) == .hidden
    )
  }

  @Test func highlightCardVisibleWhenPinnedOn() {
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: true,
        dismissedAt: .distantPast
      ) == .visible
    )
  }

  @Test func highlightCardHiddenWhenDismissedAfterRelevance() {
    let afterRelevance = HighlightRelevantOnboardingCardView.cardRelevantSinceDate.addingTimeInterval(1)
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        groupPinnedRows: true,
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
        dismissedAt: atBoundary
      ) == .hidden
    )
  }
}
