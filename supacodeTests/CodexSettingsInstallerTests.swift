import ConcurrencyExtras
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct CodexSettingsInstallerTests {
  private let fileManager = FileManager.default

  private func makeTempHomeURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("supacode-codex-installer-\(UUID().uuidString)", isDirectory: true)
  }

  @Test func installAllHooksRunsEnableHooksCommand() async throws {
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

    try await installer.installAllHooks()

    #expect(runCount.value == 1)
    #expect(fileManager.fileExists(atPath: CodexSettingsInstaller.settingsURL(homeDirectoryURL: homeURL).path))
  }

  @Test func installAllHooksThrowsCodexUnavailable() async {
    let homeURL = makeTempHomeURL()
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: {
        throw CodexSettingsInstallerError.codexUnavailable
      }
    )

    do {
      try await installer.installAllHooks()
      Issue.record("Expected codexUnavailable error")
    } catch let error as CodexSettingsInstallerError {
      #expect(error == .codexUnavailable)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func installAllHooksThrowsEnableHooksFailedForNonZeroExit() async {
    let homeURL = makeTempHomeURL()
    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: {
        .init(status: 1, standardError: "boom")
      }
    )

    do {
      try await installer.installAllHooks()
      Issue.record("Expected enableHooksFailed error")
    } catch let error as CodexSettingsInstallerError {
      #expect(error == .enableHooksFailed("boom"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func uninstallAllHooksStripsFeaturesHooksFlag() async throws {
    // Reproduces the partial-install rollback gap: install writes
    // `[features].hooks = true` to config.toml; uninstall must strip
    // it so the row reports `.notInstalled` instead of `.outdated`.
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let configURL = homeURL.appendingPathComponent(".codex/config.toml", isDirectory: false)
    try fileManager.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[features]\nhooks = true\n".write(to: configURL, atomically: true, encoding: .utf8)

    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: { .init(status: 0, standardError: "") }
    )
    try await installer.installAllHooks()
    try installer.uninstallAllHooks()

    let after = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    #expect(!after.contains("hooks = true"))
    #expect(installer.installState() == .notInstalled)
  }

  @Test func featuresStateIgnoresCommentedLegacyFlag() async throws {
    // Reproduces the regex misclassification: `# codex_hooks = true`
    // must NOT count as `.legacy` — only the live `hooks = true` line
    // should drive the state.
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let configURL = homeURL.appendingPathComponent(".codex/config.toml", isDirectory: false)
    try fileManager.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[features]\n# codex_hooks = true (deprecated, see docs)\nhooks = true\n"
      .write(to: configURL, atomically: true, encoding: .utf8)

    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: { .init(status: 0, standardError: "") }
    )
    try await installer.installAllHooks()
    // After install, the state should be `.installed` — not `.outdated`
    // (which is what the old regex returned because the comment
    // false-matched as legacy).
    #expect(installer.installState() == .installed)
  }

  @Test func featuresStateScansPastTomlArrayValues() async throws {
    // Reproduces the regex `[^\[]*` truncation on a TOML array between
    // the `[features]` header and `hooks = true`.
    let homeURL = makeTempHomeURL()
    defer { try? fileManager.removeItem(at: homeURL) }
    let configURL = homeURL.appendingPathComponent(".codex/config.toml", isDirectory: false)
    try fileManager.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "[features]\nplugins = [\"a\", \"b\"]\nhooks = true\n"
      .write(to: configURL, atomically: true, encoding: .utf8)

    let installer = CodexSettingsInstaller(
      homeDirectoryURL: homeURL,
      fileManager: fileManager,
      runEnableHooksCommand: { .init(status: 0, standardError: "") }
    )
    try await installer.installAllHooks()
    #expect(installer.installState() == .installed)
  }
}
