import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct CodingAgentsSidebarCardModeTests {
  @Test func anyInstalledSuppressesPromptInstall() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.installed),
      .codex: .ready(.notInstalled),
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .hidden)
  }

  @Test func dismissedSuppressesPromptInstall() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.notInstalled),
      .codex: .ready(.notInstalled),
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: true) == .hidden)
  }

  @Test func nothingInstalledAndNotDismissedShowsPromptInstall() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.notInstalled),
      .codex: .ready(.notInstalled),
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .promptInstall)
  }

  @Test func stillCheckingSuppressesPromptInstallToAvoidLaunchFlash() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.notInstalled),
      .codex: .checking,
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .hidden)
  }

  @Test func installingAgentSuppressesPromptInstallToAvoidMidFlightFlap() {
    // While an agent is mid-install we can't know its final state, so suppress
    // the prompt card so it doesn't flash off, then back on, on completion.
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.notInstalled),
      .codex: .installing,
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .hidden)
  }

  @Test func uninstallingAgentSuppressesPromptInstallToAvoidMidFlightFlap() {
    // Symmetric to the installing case: an in-flight uninstall shouldn't
    // race the prompt card.
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.installed),
      .codex: .uninstalling,
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .hidden)
  }

  @Test func failedAgentCountsAsResolvedAndDoesNotBlockPrompt() {
    // A failed integration check resolved (we know the result); it just
    // resolved to "we can't tell", not "still in flight". Treat as resolved
    // so a single failed agent doesn't permanently suppress the prompt.
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.notInstalled),
      .claude: .ready(.notInstalled),
      .codex: .failed("boom"),
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.notInstalled),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .promptInstall)
  }

  @Test func outdatedAgentAloneDoesNotSurfaceACard() {
    // Outdated integrations are re-installed automatically, so an outdated
    // agent alongside an installed one leaves the card hidden.
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .antigravity: .ready(.installed),
      .claude: .ready(.outdated),
      .codex: .ready(.installed),
      .copilot: .ready(.installed),
      .grok: .ready(.installed),
      .hermes: .ready(.installed),
      .kimi: .ready(.installed),
      .kiro: .ready(.installed),
      .omp: .ready(.installed),
      .opencode: .ready(.installed),
      .pi: .ready(.installed),
    ]
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .hidden)
  }

  @Test(arguments: [nil, AgentIntegrationState.installed])
  func undeterminedStateSuppressesPromptInstall(lastKnown: AgentIntegrationState?) {
    // An unreadable probe must not read as "nobody has it installed": the card
    // would nag a user to install an integration that is already in place, and
    // its Install path would throw against the same unreadable file. Covers the
    // cold launch (no prior verdict) too.
    var states: [SkillAgent: AgentIntegrationRowState] = [:]
    for agent in SkillAgent.allCases { states[agent] = .ready(.notInstalled) }
    states[.claude] = .undetermined(lastKnown: lastKnown, reason: "Couldn't read it.")

    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false) == .hidden)
  }

  @Test func dismissedAtBeforeCutoffReEngages() {
    // Stamps older than `cardRelevantSinceDate` are stale; re-engagement is
    // bumping the cutoff at material changes, no key sprawl required.
    let cutoff = Date(timeIntervalSince1970: 1_000_000_000)
    let stale = cutoff.addingTimeInterval(-1)
    let future = cutoff.addingTimeInterval(86_400)
    #expect(CodingAgentsSidebarCardView.isDismissed(at: .distantPast, relevantSince: cutoff) == false)
    #expect(CodingAgentsSidebarCardView.isDismissed(at: stale, relevantSince: cutoff) == false)
    #expect(CodingAgentsSidebarCardView.isDismissed(at: cutoff, relevantSince: cutoff) == true)
    #expect(CodingAgentsSidebarCardView.isDismissed(at: future, relevantSince: cutoff) == true)
  }

  @Test func cardRelevantSinceDateMatchesAntigravityLaunchReEngagement() {
    let antigravityLaunchCutoff = Date(timeIntervalSince1970: 1_784_937_600)
    let previouslyDismissedUser = Date(timeIntervalSince1970: 1_783_382_400)

    #expect(CodingAgentsSidebarCardView.cardRelevantSinceDate == antigravityLaunchCutoff)
    #expect(CodingAgentsSidebarCardView.isDismissed(at: previouslyDismissedUser) == false)
  }
}
