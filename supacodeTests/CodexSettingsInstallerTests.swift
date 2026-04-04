import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

struct CodexSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-codex-installer-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installProgressHooksRunsEnableHooksCommand() async throws {
    let homeURL = makeTempHomeURL()
    let runCount = LockIsolated(0)
    defer { try? fileManager.removeItem(at: homeURL) }

    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: {
        runCount.setValue(runCount.value + 1)
        return .init(status: 0, standardError: "")
      }
    )

    try await installer.installProgressHooks()

    #expect(runCount.value == 1)
    #expect(fileManager.fileExists(atPath: CodexSettingsInstaller.settingsURL(homeDirectoryURL: homeURL).path))
  }

  @Test func installProgressHooksThrowsCodexUnavailable() async {
    let homeURL = makeTempHomeURL()
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: {
        throw CodexSettingsInstallerError.codexUnavailable
      }
    )

    do {
      try await installer.installProgressHooks()
      Issue.record("Expected codexUnavailable error")
    } catch let error as CodexSettingsInstallerError {
      #expect(error == .codexUnavailable)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func installProgressHooksThrowsEnableHooksFailedForNonZeroExit() async {
    let homeURL = makeTempHomeURL()
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: {
        .init(status: 1, standardError: "boom")
      }
    )

    do {
      try await installer.installProgressHooks()
      Issue.record("Expected enableHooksFailed error")
    } catch let error as CodexSettingsInstallerError {
      #expect(error == .enableHooksFailed("boom"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
