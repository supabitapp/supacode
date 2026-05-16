import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarBottomCardTests {
  @Test func agentUpdatesWinOverOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .updatesAvailable([.claude]),
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.updatesAvailable([.claude])))
  }

  @Test func agentPromptWinsOverOnboarding() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .promptInstall,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func onboardingShowsWhenAgentIsHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
      onboardingMode: .visible
    )
    #expect(resolved == .nestedWorktreesOnboarding)
  }

  @Test func noneWhenBothHidden() {
    let resolved = SidebarBottomCardView.Slot.resolve(
      agentMode: .hidden,
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
}
