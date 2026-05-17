import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarBottomCardTests {
  @Test func agentUpdatesWinOverOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .updatesAvailable([.claude]),
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.updatesAvailable([.claude])))
  }

  @Test func agentPromptWinsOverOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .promptInstall,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func highlightWinsOverNestedOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      highlightMode: .visible,
      onboardingMode: .visible
    )
    #expect(resolved == .highlightRelevantOnboarding)
  }

  @Test func nestedOnboardingShowsWhenHighlightDismissed() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      highlightMode: .hidden,
      onboardingMode: .visible
    )
    #expect(resolved == .nestedWorktreesOnboarding)
  }

  @Test func noneWhenAllHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      highlightMode: .hidden,
      onboardingMode: .hidden
    )
    #expect(resolved == SidebarBottomCardView.Slot.none)
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
        highlightRelevant: false,
        dismissedAt: .distantPast
      ) == .hidden
    )
  }

  @Test func highlightCardVisibleWhenToggleOnAndNotDismissed() {
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        highlightRelevant: true,
        dismissedAt: .distantPast
      ) == .visible
    )
  }

  @Test func highlightCardHiddenWhenDismissedAfterRelevance() {
    let afterRelevance = HighlightRelevantOnboardingCardView.cardRelevantSinceDate.addingTimeInterval(1)
    #expect(
      HighlightRelevantOnboardingCardView.resolveMode(
        highlightRelevant: true,
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
        highlightRelevant: true,
        dismissedAt: atBoundary
      ) == .hidden
    )
  }
}
