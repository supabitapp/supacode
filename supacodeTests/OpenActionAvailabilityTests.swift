import Dependencies
import DependenciesTestSupport
import Testing

@testable import SupacodeSettingsShared

struct OpenActionAvailabilityTests {
  private nonisolated static let installed: [OpenWorktreeAction] = [
    .cursor, .vscode, .finder, .terminal, .editor,
  ]

  /// The live sweep is the only thing standing between the menu and an editor the
  /// user doesn't have. Asserted against the host's real LaunchServices answers,
  /// so the test stays deterministic whatever is installed.
  @Test func liveInstalledActionsKeepMenuOrderAndFilterOnLaunchServices() {
    let live = OpenActionAvailabilityClient.liveValue
    let installed = live.installedActions()

    // Menu order is preserved (the picker and the Open menu render this verbatim).
    #expect(installed == OpenWorktreeAction.menuOrder.filter { installed.contains($0) })
    // Unconditional actions are always offered, whatever LaunchServices says.
    #expect(installed.contains(.finder))
    #expect(installed.contains(.editor))
    for action in installed where action.requiresInstalledApplication {
      #expect(live.applicationURL(action.bundleIdentifier) != nil, "\(action.title) is not installed.")
    }
    for action in OpenWorktreeAction.menuOrder where !installed.contains(action) {
      #expect(action.requiresInstalledApplication)
      #expect(live.applicationURL(action.bundleIdentifier) == nil, "\(action.title) is installed.")
    }
  }

  @Test func testFixtureStaysDeterministicSoResolutionDoesNotDependOnTheHost() {
    @Dependency(\.openActionAvailability) var availability
    #expect(availability.installedActions() == [.zed, .finder, .terminal, .editor])
  }

  @Test func preferredDefaultPicksTheHighestPriorityInstalledEditor() {
    #expect(OpenWorktreeAction.preferredDefault(installed: Self.installed) == .cursor)
    #expect(OpenWorktreeAction.preferredDefault(installed: [.vscode, .finder]) == .vscode)
    #expect(OpenWorktreeAction.preferredDefault(installed: [.terminal, .finder]) == .finder)
  }

  @Test func preferredDefaultFallsBackToFinderWhenNothingIsInstalled() {
    #expect(OpenWorktreeAction.preferredDefault(installed: []) == .finder)
  }

  @Test func availableSelectionKeepsInstalledSelectionAndReplacesMissingOne() {
    #expect(OpenWorktreeAction.availableSelection(.vscode, installed: Self.installed) == .vscode)
    #expect(OpenWorktreeAction.availableSelection(.zed, installed: Self.installed) == .cursor)
  }

  @Test func fromSettingsIDPrefersTheExplicitRepositorySelection() {
    let action = OpenWorktreeAction.fromSettingsID(
      OpenWorktreeAction.terminal.settingsID,
      defaultEditorID: OpenWorktreeAction.vscode.settingsID,
      installed: Self.installed
    )
    #expect(action == .terminal)
  }

  @Test func fromSettingsIDFallsBackToTheDefaultEditor() {
    let action = OpenWorktreeAction.fromSettingsID(
      OpenWorktreeAction.automaticSettingsID,
      defaultEditorID: OpenWorktreeAction.vscode.settingsID,
      installed: Self.installed
    )
    #expect(action == .vscode)
  }

  @Test func fromSettingsIDIgnoresADefaultEditorThatIsNotInstalled() {
    let action = OpenWorktreeAction.fromSettingsID(
      nil,
      defaultEditorID: OpenWorktreeAction.windsurf.settingsID,
      installed: Self.installed
    )
    #expect(action == .cursor)
  }

  @Test func normalizedDefaultEditorIDDropsAnUninstalledEditor() {
    #expect(
      OpenWorktreeAction.normalizedDefaultEditorID(
        OpenWorktreeAction.windsurf.settingsID,
        installed: Self.installed
      ) == OpenWorktreeAction.automaticSettingsID
    )
    #expect(
      OpenWorktreeAction.normalizedDefaultEditorID(
        OpenWorktreeAction.vscode.settingsID,
        installed: Self.installed
      ) == OpenWorktreeAction.vscode.settingsID
    )
  }

  @Test func onlyTheEditorActionRendersASymbol() {
    #expect(OpenWorktreeAction.editor.menuSymbolName == "apple.terminal")
    #expect(OpenWorktreeAction.allCases.filter { $0.menuSymbolName != nil } == [.editor])
  }

  @Test func finderAndEditorNeverRequireAnInstalledBundle() {
    let unconditional = OpenWorktreeAction.allCases.filter { !$0.requiresInstalledApplication }
    #expect(Set(unconditional) == [.finder, .editor])
  }
}
