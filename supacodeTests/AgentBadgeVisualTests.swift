import SupacodeSettingsShared
import Testing

@testable import supacode

struct AgentBadgeVisualTests {
  @Test func resolvesEachActivityToItsVariant() {
    #expect(AgentBadgeVisual.resolve(.idle) == .normal)
    #expect(AgentBadgeVisual.resolve(.busy) == .normal)
    #expect(AgentBadgeVisual.resolve(.awaitingInput) == .awaitingInput)
    #expect(AgentBadgeVisual.resolve(.compacting) == .compacting)
    #expect(AgentBadgeVisual.resolve(.error) == .error)
  }

  @Test func errorAndCompactingDescribeThemselvesBeyondTheAgentName() {
    // The avatar group ignores its children for accessibility and folds these in,
    // so a variant that reads as the bare agent name is invisible to VoiceOver.
    #expect(AgentBadgeVisual.error.describing(.claude) != SkillAgent.claude.displayName)
    #expect(AgentBadgeVisual.compacting.describing(.claude) != SkillAgent.claude.displayName)
    #expect(AgentBadgeVisual.normal.describing(.claude) == SkillAgent.claude.displayName)
  }
}
