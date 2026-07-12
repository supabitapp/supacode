import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct CodingAgentsSidebarCardModeTests {
  @Test func anyOutdatedAgentReturnsUpdatesAvailableWithJustThoseAgents() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
      .claude: .ready(.installed),
      .codex: .ready(.outdated),
      .copilot: .ready(.notInstalled),
      .grok: .ready(.notInstalled),
      .hermes: .ready(.notInstalled),
      .kimi: .ready(.notInstalled),
      .kiro: .ready(.outdated),
      .omp: .ready(.notInstalled),
      .opencode: .ready(.notInstalled),
      .pi: .ready(.notInstalled),
    ]
    let mode = CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false)
    guard case .updatesAvailable(let agents) = mode else {
      Issue.record("Expected .updatesAvailable, got \(mode)")
      return
    }
    #expect(agents == [.codex, .kiro])
  }

  @Test func updatesCardShowsEvenIfDismissed() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    let mode = CodingAgentsSidebarCardView.mode(for: states, dismissed: true, autoUpdateEnabled: false)
    #expect(mode == .updatesAvailable([.claude]))
  }

  @Test func anyInstalledSuppressesPromptInstall() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false) == .hidden)
  }

  @Test func dismissedSuppressesPromptInstall() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: true, autoUpdateEnabled: false) == .hidden)
  }

  @Test func nothingInstalledAndNotDismissedShowsPromptInstall() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false) == .promptInstall)
  }

  @Test func stillCheckingSuppressesPromptInstallToAvoidLaunchFlash() {
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false) == .hidden)
  }

  @Test func installingAgentSuppressesPromptInstallToAvoidMidFlightFlap() {
    // While an agent is mid-install we can't know its final state, so suppress
    // the prompt card so it doesn't flash off, then back on, on completion.
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false) == .hidden)
  }

  @Test func uninstallingAgentSuppressesPromptInstallToAvoidMidFlightFlap() {
    // Symmetric to the installing case: an in-flight uninstall shouldn't
    // race the prompt card.
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false) == .hidden)
  }

  @Test func failedAgentCountsAsResolvedAndDoesNotBlockPrompt() {
    // A failed integration check resolved (we know the result); it just
    // resolved to "we can't tell", not "still in flight". Treat as resolved
    // so a single failed agent doesn't permanently suppress the prompt.
    let states: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(CodingAgentsSidebarCardView.mode(for: states, dismissed: false, autoUpdateEnabled: false) == .promptInstall)
  }

  @Test func autoUpdateEnabledSuppressesUpdatesAvailableCard() {
    // The card is dead UI when auto-update is on; the system already
    // re-installs outdated agents on every refresh. The prompt-install
    // card still surfaces for the never-installed case.
    let outdated: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(
      CodingAgentsSidebarCardView.mode(for: outdated, dismissed: false, autoUpdateEnabled: true) == .hidden
    )

    let untouched: [SkillAgent: AgentIntegrationRowState] = [
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
    #expect(
      CodingAgentsSidebarCardView.mode(for: untouched, dismissed: false, autoUpdateEnabled: true) == .promptInstall
    )
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

  @Test func cardRelevantSinceDateMatchesGrokLaunchReEngagement() {
    let grokLaunchCutoff = Date(timeIntervalSince1970: 1_783_382_400)
    let previouslyDismissedUser = Date(timeIntervalSince1970: 1_783_209_600)

    #expect(CodingAgentsSidebarCardView.cardRelevantSinceDate == grokLaunchCutoff)
    #expect(CodingAgentsSidebarCardView.isDismissed(at: previouslyDismissedUser) == false)
  }
}
