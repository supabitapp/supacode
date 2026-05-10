import Darwin
import Foundation

private nonisolated let codexInstallerLogger = SupaLogger("Settings")

nonisolated struct CodexSettingsInstaller {
  struct CommandResult: Equatable, Sendable {
    let status: Int32
    let standardError: String
  }

  let homeDirectoryURL: URL
  let fileManager: FileManager
  let runEnableHooksCommand: @Sendable () async throws -> CommandResult

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.init(
      homeDirectoryURL: homeDirectoryURL,
      fileManager: fileManager,
      runEnableHooksCommand: Self.runEnableHooksCommand
    )
  }

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    runEnableHooksCommand: @escaping @Sendable () async throws -> CommandResult
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
    self.runEnableHooksCommand = runEnableHooksCommand
  }

  /// Combined progress + notification install state — see
  /// `ClaudeSettingsInstaller.installState()` for rationale.
  func installState() -> ComponentInstallState {
    let groups: [String: [JSONValue]]
    do {
      groups = try CodexHookSettings.allHooksByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error)
      return .notInstalled
    }
    let hooksState = fileInstaller.installState(settingsURL: settingsURL, hookGroupsByEvent: groups)
    let featuresState = featuresConfigState()
    switch (hooksState, featuresState) {
    case (.installed, .upToDate): return .installed
    case (.notInstalled, .absent): return .notInstalled
    default: return .outdated
    }
  }

  func installAllHooks() async throws {
    try await enableHooksFeature()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try CodexHookSettings.allHooksByEvent()
    )
  }

  func uninstallAllHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try CodexHookSettings.allHooksByEvent()
    )
    // Symmetric with `enableHooksFeature` in install — without this, a
    // partial-install rollback (or a plain uninstall) leaves
    // `[features].hooks = true` stranded on disk so `installState` reports
    // `.outdated` forever with no path back to `.notInstalled`.
    disableHooksFeatureFlag()
  }

  private enum FeaturesConfigState {
    case absent  // Neither flag set.
    case upToDate  // Only the new `hooks` flag set.
    case legacy  // `codex_hooks` is present (with or without `hooks`).
  }

  /// Inspect `~/.codex/config.toml` for the hooks feature flags. Walks
  /// lines so a TOML array value (`plugins = ["x"]`) inside the section
  /// can't truncate detection, and a commented-out `# codex_hooks = true`
  /// can't false-positive as `.legacy`.
  private func featuresConfigState() -> FeaturesConfigState {
    let url = homeDirectoryURL.appending(
      path: ".codex/config.toml", directoryHint: .notDirectory)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return .absent }
    let flags = Self.featuresFlags(in: contents)
    if flags.legacy { return .legacy }
    if flags.modern { return .upToDate }
    return .absent
  }

  /// Walk `[features]` table lines, returning whether each flag is set.
  /// Both detection (`featuresConfigState`) and removal
  /// (`stripLegacyCodexHooksFlag`) share this predicate so they cannot
  /// disagree on what counts as "legacy".
  private static func featuresFlags(in contents: String) -> (legacy: Bool, modern: Bool) {
    var legacy = false
    var modern = false
    var inFeaturesSection = false
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      if let header = tomlSectionName(in: line) {
        inFeaturesSection = (header == "features")
        continue
      }
      guard inFeaturesSection else { continue }
      if line.range(of: #"^\s*codex_hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
        legacy = true
      } else if line.range(of: #"^\s*hooks\s*=\s*true\b"#, options: .regularExpression) != nil {
        modern = true
      }
    }
    return (legacy, modern)
  }

  /// Returns the section name when `line` is a TOML section header
  /// (e.g. `[features]`, `[ features ]`, `[features] # comment`).
  /// Trailing `#`-comments are stripped before the bracket check; missing
  /// either bracket → not a header. The bracketed inner text is trimmed so
  /// `[ features ]` matches `features`.
  static func tomlSectionName(in line: Substring) -> String? {
    let withoutComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else { return nil }
    let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
    return inner.isEmpty ? nil : inner
  }

  private func enableHooksFeature() async throws {
    let commandResult = try await runEnableHooksCommand()
    guard commandResult.status == 0 else {
      throw CodexSettingsInstallerError.enableHooksFailed(commandResult.standardError)
    }
    stripLegacyCodexHooksFlag()
  }

  /// Remove the deprecated `[features].codex_hooks = true` line from
  /// `~/.codex/config.toml` if present. Codex's CLI doesn't clean up the
  /// old flag when enabling the new one, and leaving it surfaces as
  /// outdated in `installState`. A silent `try?` here would loop the user
  /// on "Update" forever if the write actually fails (read-only mount,
  /// ACL), so log it.
  private func stripLegacyCodexHooksFlag() {
    rewriteFeaturesSection { line, inFeaturesSection in
      guard inFeaturesSection,
        line.range(of: #"^\s*codex_hooks\s*=\s*true\b"#, options: .regularExpression) != nil
      else { return line }
      return nil
    }
  }

  /// Strip `hooks = true` from `[features]`. Used by uninstall so the
  /// rollback path leaves the section in the same shape it found it —
  /// otherwise a partial-install rollback (hooks file cleared, feature
  /// flag stranded) reports `.outdated` forever with no path back to
  /// `.notInstalled`.
  private func disableHooksFeatureFlag() {
    rewriteFeaturesSection { line, inFeaturesSection in
      guard inFeaturesSection,
        line.range(of: #"^\s*hooks\s*=\s*true\b"#, options: .regularExpression) != nil
      else { return line }
      return nil
    }
  }

  /// Walk `~/.codex/config.toml` line by line, replacing each line in
  /// the `[features]` section via `transform` (return `nil` to drop).
  /// No-op when the file doesn't exist or no transform produced a change.
  private func rewriteFeaturesSection(
    transform: (Substring, _ inFeaturesSection: Bool) -> Substring?
  ) {
    let url = homeDirectoryURL.appending(
      path: ".codex/config.toml", directoryHint: .notDirectory)
    let original: String
    do {
      original = try String(contentsOf: url, encoding: .utf8)
    } catch {
      let nsError = error as NSError
      if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
        codexInstallerLogger.warning(
          "Failed to read \(url.path) before rewrite: \(error)")
      }
      return
    }
    var output: [Substring] = []
    var inFeaturesSection = false
    for line in original.split(separator: "\n", omittingEmptySubsequences: false) {
      if let header = Self.tomlSectionName(in: line) {
        inFeaturesSection = (header == "features")
        output.append(line)
        continue
      }
      if let kept = transform(line, inFeaturesSection) {
        output.append(kept)
      }
    }
    let rewritten = output.joined(separator: "\n")
    guard rewritten != original else { return }
    do {
      try rewritten.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      codexInstallerLogger.warning(
        "Failed to rewrite \(url.path): \(error)")
    }
  }

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("hooks.json", isDirectory: false)
  }

  static func runEnableHooksCommand() async throws -> CommandResult {
    let process = Process()
    process.executableURL = loginShellURL()
    // `codex_hooks` was renamed to `hooks` in newer Codex versions; the legacy name is deprecated.
    process.arguments = ["-l", "-c", "codex features enable hooks"]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    let status = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        continuation.resume(returning: process.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        continuation.resume(throwing: error)
      }
    }
    let standardError =
      String(bytes: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if status == 127 {
      throw CodexSettingsInstallerError.codexUnavailable
    }
    return .init(status: status, standardError: standardError.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func loginShellURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentUserShellPath: String? = currentUserShellPath()
  ) -> URL {
    let shellPath =
      normalizedShellPath(currentUserShellPath)
      ?? normalizedShellPath(environment["SHELL"])
      ?? "/bin/zsh"
    return URL(fileURLWithPath: shellPath)
  }

  private static func currentUserShellPath() -> String? {
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
    return String(cString: shell)
  }

  private static func normalizedShellPath(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
      return nil
    }
    return path
  }

  private static func reportInvalidHookConfiguration(_ error: Error) {
    #if DEBUG
      assertionFailure("Codex hook configuration is invalid: \(error)")
    #endif
  }

  private var fileInstaller: AgentHookSettingsFileInstaller {
    AgentHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { CodexSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { CodexSettingsInstallerError.invalidHooksObject },
        invalidJSON: { CodexSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { CodexSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum CodexSettingsInstallerError: Error, Equatable, LocalizedError {
  case codexUnavailable
  case enableHooksFailed(String)
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject

  var errorDescription: String? {
    switch self {
    case .codexUnavailable:
      "Codex must be installed and available in your login shell before Supacode can install hooks."
    case .enableHooksFailed(let details):
      details.isEmpty
        ? "Supacode could not enable the Codex hooks feature."
        : "Supacode could not enable the Codex hooks feature: \(details)"
    case .invalidEventHooks(let event):
      "Codex hooks use an unsupported shape for \(event)."
    case .invalidHooksObject:
      "Codex hooks use an unsupported shape."
    case .invalidJSON(let detail):
      "Codex hooks must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Codex hooks must be a JSON object before Supacode can install hooks."
    }
  }
}
