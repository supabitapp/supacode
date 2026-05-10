import Foundation
import Testing

@testable import SupacodeSettingsShared

struct AgentIntegrationTests {
  @Test func stateIsInstalledWhenAllComponentsReportInstalled() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .unifiedHooks, installed: true),
        component(kind: .cliSkill, installed: true),
      ]
    )
    #expect(integration.state() == .installed)
  }

  @Test func stateIsNotInstalledWhenAllComponentsAbsent() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .unifiedHooks, installed: false),
        component(kind: .cliSkill, installed: false),
      ]
    )
    #expect(integration.state() == .notInstalled)
  }

  @Test func stateIsOutdatedWhenSomeMissing() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .unifiedHooks, state: .installed),
        component(kind: .cliSkill, state: .notInstalled),
      ]
    )
    #expect(integration.state() == .outdated)
  }

  @Test func stateIsOutdatedWhenAnyComponentReportsOutdated() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .unifiedHooks, state: .outdated),
        component(kind: .cliSkill, state: .installed),
      ]
    )
    #expect(integration.state() == .outdated)
  }

  @Test func installRunsComponentsFrontToBack() async throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(label: "first", recorder: order),
        recordingComponent(label: "second", recorder: order),
        recordingComponent(label: "third", recorder: order),
      ]
    )
    try await integration.install()
    #expect(await order.installs == ["first", "second", "third"])
  }

  @Test func uninstallRunsComponentsBackToFront() throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(label: "first", recorder: order),
        recordingComponent(label: "second", recorder: order),
        recordingComponent(label: "third", recorder: order),
      ]
    )
    try integration.uninstall()
    #expect(order.uninstallsSync == ["third", "second", "first"])
  }

  @Test func partialInstallFailureRollsBackInReverseOrder() async throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(label: "first", recorder: order),
        recordingComponent(label: "second", recorder: order),
        AgentIntegration.Component(
          kind: .cliSkill,
          state: { .notInstalled },
          install: { throw TestError.boom },
          // Should never run during rollback — the throwing component
          // didn't complete, so there's nothing to undo.
          uninstall: {}
        ),
      ]
    )
    do {
      try await integration.install()
      Issue.record("Expected install to throw")
    } catch {
      // First two components installed; third threw and rolled them back in reverse.
      #expect(await order.installs == ["first", "second"])
      #expect(order.uninstallsSync == ["second", "first"])
    }
  }

  @Test func uninstallSweepsAllComponentsEvenWhenOneFails() throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(label: "first", recorder: order),
        AgentIntegration.Component(
          kind: .cliSkill,
          state: { .notInstalled },
          install: {},
          uninstall: { throw TestError.boom }
        ),
        recordingComponent(label: "third", recorder: order),
      ]
    )
    do {
      try integration.uninstall()
      Issue.record("Expected uninstall to rethrow first error")
    } catch {
      // The middle component threw, but uninstall continues so the others get cleaned up.
      #expect(order.uninstallsSync == ["third", "first"])
    }
  }

  // MARK: - Helpers.

  private func component(
    kind: AgentIntegration.Component.Kind, installed: Bool
  ) -> AgentIntegration.Component {
    component(kind: kind, state: installed ? .installed : .notInstalled)
  }

  private func component(
    kind: AgentIntegration.Component.Kind, state: ComponentInstallState
  ) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: kind,
      state: { state },
      install: {},
      uninstall: {}
    )
  }

  private func recordingComponent(
    label: String, recorder: OrderRecorder
  ) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: .unifiedHooks,
      state: { .notInstalled },
      install: { await recorder.recordInstall(label) },
      uninstall: { recorder.recordUninstallSync(label) }
    )
  }
}

private enum TestError: Error { case boom }

/// Two recording surfaces: `installs` is read async (install closures are
/// `async throws`); `uninstallsSync` is read sync (uninstall closures are sync
/// throws). Splitting avoids needing an actor for the sync side. Labels are
/// arbitrary strings so tests can name components without coupling to the
/// production `Component.Kind` enum.
private final class OrderRecorder: @unchecked Sendable {
  private var _uninstallsSync: [String] = []
  private let installState = InstallRecorder()

  var installs: [String] {
    get async { await installState.values }
  }

  var uninstallsSync: [String] { _uninstallsSync }

  func recordInstall(_ label: String) async {
    await installState.append(label)
  }

  func recordUninstallSync(_ label: String) {
    _uninstallsSync.append(label)
  }
}

private actor InstallRecorder {
  private var _values: [String] = []
  var values: [String] { _values }
  func append(_ label: String) { _values.append(label) }
}
