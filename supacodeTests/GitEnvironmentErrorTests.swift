import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct GitEnvironmentErrorTests {
  @Test func classifiesLicenseGateFromDirectGitStderr() {
    let error = ShellClientError(
      command: "/usr/bin/env git --version",
      stdout: "",
      stderr: "You have not agreed to the Xcode license agreements. "
        + "Please run 'sudo xcodebuild -license' from within a Terminal to review and accept them.",
      exitCode: 69
    )
    #expect(GitEnvironmentError(classifying: error) == .xcodeLicenseNotAccepted)
  }

  @Test func classifiesLicenseGateThroughWtShimMaskedExitCode() {
    // The bundled `wt` shim re-emits git's stderr but exits 1 via `die`, so the
    // exit code is masked; detection must key off the stderr text alone.
    let error = GitClientError.commandFailed(
      command: "wt ls --json",
      message: "stderr:\nYou have not agreed to the Xcode license agreements. "
        + "Please run 'sudo xcodebuild -license'.\nerror: not a git repository"
    )
    #expect(GitEnvironmentError(classifying: error) == .xcodeLicenseNotAccepted)
  }

  @Test func classifiesAdminPrivilegeLicenseVariant() {
    // A phrasing that omits "agreed to" but still routes through `xcodebuild
    // -license`, the invariant the detector keys on.
    let error = ShellClientError(
      command: "git",
      stdout: "",
      stderr: "Agreeing to the Xcode/iOS license requires admin privileges, "
        + "please run 'sudo xcodebuild -license' and then retry this command.",
      exitCode: 69
    )
    #expect(GitEnvironmentError(classifying: error) == .xcodeLicenseNotAccepted)
  }

  @Test func classifiesInvalidActiveDeveloperPath() {
    let error = ShellClientError(
      command: "git",
      stdout: "",
      stderr: "xcrun: error: invalid active developer path "
        + "(/Library/Developer/CommandLineTools), missing xcrun at: ...",
      exitCode: 1
    )
    #expect(GitEnvironmentError(classifying: error) == .developerToolsUnavailable)
  }

  @Test func classifiesToolRequiresXcode() {
    let error = ShellClientError(
      command: "git",
      stdout: "",
      stderr: "xcode-select: error: tool 'git' requires Xcode, but active developer "
        + "directory '/Library/Developer/CommandLineTools' is a command line tools instance",
      exitCode: 1
    )
    #expect(GitEnvironmentError(classifying: error) == .developerToolsUnavailable)
  }

  @Test func repositorySpecificFailureIsNotEnvironmental() {
    let error = GitClientError.commandFailed(
      command: "git worktree list",
      message: "stderr:\nfatal: not a git repository (or any of the parent directories): .git"
    )
    #expect(GitEnvironmentError(classifying: error) == nil)
  }

  @Test func remedyCommandsMatchTheGate() {
    #expect(GitEnvironmentError.xcodeLicenseNotAccepted.remedyCommand == "sudo xcodebuild -license accept")
    #expect(GitEnvironmentError.developerToolsUnavailable.remedyCommand == "xcode-select --install")
  }
}

/// Probe-level behavior of `GitClient.gitEnvironmentError()` (the authoritative
/// `git --version` check the loader relies on), using an injected fake shell.
struct GitEnvironmentProbeTests {
  private static func shell(
    throwing error: ShellClientError?,
    record store: ShellCallStore? = nil
  ) -> ShellClient {
    ShellClient(
      run: { _, arguments, _ in
        if let store { await store.record(arguments) }
        if let error { throw error }
        return ShellOutput(stdout: "git version 2.44.0", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
  }

  @Test func healthyGitReportsNoEnvironmentError() async {
    let result = await GitClient(shell: Self.shell(throwing: nil)).gitEnvironmentError()
    #expect(result == nil)
  }

  @Test func probePinsCLocaleAndClassifiesLicenseGate() async {
    // The probe must pin C locale so its diagnostics classify regardless of the
    // user's system language.
    let store = ShellCallStore()
    let licenseError = ShellClientError(
      command: "git --version", stdout: "",
      stderr: "You have not agreed to the Xcode license agreements. "
        + "Please run 'sudo xcodebuild -license'.",
      exitCode: 69
    )
    let result = await GitClient(shell: Self.shell(throwing: licenseError, record: store))
      .gitEnvironmentError()
    #expect(result == .xcodeLicenseNotAccepted)
    let calls = await store.calls
    #expect(Array(calls.first?.prefix(2) ?? []) == ["LC_ALL=C", "LANG=C"])
  }

  @Test func missingGitBinaryFallsBackToDeveloperTools() async {
    // A missing binary (exit 127) has no gate signature, but git is still
    // unusable, so the probe surfaces the command-line-tools remedy rather than
    // pretending git is healthy.
    let notFound = ShellClientError(
      command: "/usr/bin/env git --version", stdout: "",
      stderr: "env: git: No such file or directory", exitCode: 127
    )
    let result = await GitClient(shell: Self.shell(throwing: notFound)).gitEnvironmentError()
    #expect(result == .developerToolsUnavailable)
  }
}
