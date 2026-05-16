import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct SidebarBottomCardTests {
  @Test func agentUpdatesWinOverOnboarding() {
    let resolved = ResolvedCard.resolve(
      agentMode: .updatesAvailable([.claude]),
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.updatesAvailable([.claude])))
  }

  @Test func agentPromptWinsOverOnboarding() {
    let resolved = ResolvedCard.resolve(
      agentMode: .promptInstall,
      onboardingMode: .visible
    )
    #expect(resolved == .agent(.promptInstall))
  }

  @Test func onboardingShowsWhenAgentIsHidden() {
    let resolved = ResolvedCard.resolve(
      agentMode: .hidden,
      onboardingMode: .visible
    )
    #expect(resolved == .nestedWorktreesOnboarding)
  }

  @Test func noneWhenBothHidden() {
    let resolved = ResolvedCard.resolve(
      agentMode: .hidden,
      onboardingMode: .hidden
    )
    #expect(resolved == ResolvedCard.none)
  }

  @Test func agentVariantStableAcrossSkillAgentOrder() {
    let lhs = ResolvedCard.agent(.updatesAvailable([.claude, .codex])).transitionToken
    let rhs = ResolvedCard.agent(.updatesAvailable([.codex, .claude])).transitionToken
    #expect(lhs == rhs)
  }

  @Test func onboardingTransitionTokenUsesNestedWorktreesPrefix() {
    #expect(ResolvedCard.nestedWorktreesOnboarding.transitionToken == "nestedWorktrees:visible")
  }
}
