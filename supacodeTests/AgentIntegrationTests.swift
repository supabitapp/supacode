import Foundation
import Testing

@testable import SupacodeSettingsShared

struct AgentIntegrationTests {
  @Test func stateIsInstalledWhenAllComponentsReportInstalled() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .progressHooks, installed: true),
        component(kind: .notificationHooks, installed: true),
        component(kind: .cliSkill, installed: true),
      ]
    )
    #expect(integration.state() == .installed)
  }

  @Test func stateIsNotInstalledWhenAllComponentsAbsent() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .progressHooks, installed: false),
        component(kind: .notificationHooks, installed: false),
        component(kind: .cliSkill, installed: false),
      ]
    )
    #expect(integration.state() == .notInstalled)
  }

  @Test func stateIsPartiallyInstalledWhenSomeMissing() {
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        component(kind: .progressHooks, installed: true),
        component(kind: .notificationHooks, installed: false),
        component(kind: .cliSkill, installed: true),
      ]
    )
    #expect(integration.state() == .partiallyInstalled(missing: [.notificationHooks]))
  }

  @Test func installRunsComponentsFrontToBack() async throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(kind: .progressHooks, recorder: order),
        recordingComponent(kind: .notificationHooks, recorder: order),
        recordingComponent(kind: .cliSkill, recorder: order),
      ]
    )
    try await integration.install()
    #expect(await order.installs == [.progressHooks, .notificationHooks, .cliSkill])
  }

  @Test func uninstallRunsComponentsBackToFront() throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(kind: .progressHooks, recorder: order),
        recordingComponent(kind: .notificationHooks, recorder: order),
        recordingComponent(kind: .cliSkill, recorder: order),
      ]
    )
    try integration.uninstall()
    #expect(order.uninstallsSync == [.cliSkill, .notificationHooks, .progressHooks])
  }

  @Test func partialInstallFailureRollsBackInReverseOrder() async throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(kind: .progressHooks, recorder: order),
        recordingComponent(kind: .notificationHooks, recorder: order),
        AgentIntegration.Component(
          kind: .cliSkill,
          isInstalled: { false },
          install: { throw TestError.boom },
          uninstall: { /* should never run during rollback */  }
        ),
      ]
    )
    do {
      try await integration.install()
      Issue.record("Expected install to throw")
    } catch {
      // First two components installed; third threw and rolled them back in reverse.
      #expect(await order.installs == [.progressHooks, .notificationHooks])
      #expect(order.uninstallsSync == [.notificationHooks, .progressHooks])
    }
  }

  @Test func uninstallSweepsAllComponentsEvenWhenOneFails() throws {
    let order = OrderRecorder()
    let integration = AgentIntegration(
      agent: .claude,
      components: [
        recordingComponent(kind: .progressHooks, recorder: order),
        AgentIntegration.Component(
          kind: .notificationHooks,
          isInstalled: { false },
          install: {},
          uninstall: { throw TestError.boom }
        ),
        recordingComponent(kind: .cliSkill, recorder: order),
      ]
    )
    do {
      try integration.uninstall()
      Issue.record("Expected uninstall to rethrow first error")
    } catch {
      // The middle component threw, but uninstall continues so the others get cleaned up.
      #expect(order.uninstallsSync == [.cliSkill, .progressHooks])
    }
  }

  // MARK: - Helpers.

  private func component(
    kind: AgentIntegration.Component.Kind, installed: Bool
  ) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: kind,
      isInstalled: { installed },
      install: {},
      uninstall: {}
    )
  }

  private func recordingComponent(
    kind: AgentIntegration.Component.Kind, recorder: OrderRecorder
  ) -> AgentIntegration.Component {
    AgentIntegration.Component(
      kind: kind,
      isInstalled: { false },
      install: { await recorder.recordInstall(kind) },
      uninstall: { recorder.recordUninstallSync(kind) }
    )
  }
}

private enum TestError: Error { case boom }

/// Two recording surfaces: `installs` is read async (install closures are
/// `async throws`); `uninstallsSync` is read sync (uninstall closures are sync
/// throws). Splitting avoids needing an actor for the sync side.
private final class OrderRecorder: @unchecked Sendable {
  private var _uninstallsSync: [AgentIntegration.Component.Kind] = []
  private let installState = InstallRecorder()

  var installs: [AgentIntegration.Component.Kind] {
    get async { await installState.values }
  }

  var uninstallsSync: [AgentIntegration.Component.Kind] { _uninstallsSync }

  func recordInstall(_ id: AgentIntegration.Component.Kind) async {
    await installState.append(id)
  }

  func recordUninstallSync(_ id: AgentIntegration.Component.Kind) {
    _uninstallsSync.append(id)
  }
}

private actor InstallRecorder {
  private var _values: [AgentIntegration.Component.Kind] = []
  var values: [AgentIntegration.Component.Kind] { _values }
  func append(_ id: AgentIntegration.Component.Kind) { _values.append(id) }
}
