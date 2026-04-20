import Foundation

private nonisolated let kiroVersionLogger = SupaLogger("Settings")

nonisolated struct KiroSettingsInstaller {
  struct CommandResult: Equatable, Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
  }

  /// Version prefix we have validated Kiro's built-in `kiro_default` agent against.
  /// When the installed Kiro's first version component changes, the hardcoded
  /// defaults in `ensureDefaultAgentConfig` may no longer match upstream and would
  /// silently override a legitimately different config — gate on this prefix to
  /// fail loudly instead.
  static let supportedVersionPrefix = "1."

  /// Maximum time to wait on `kiro --version`. A misconfigured login shell (e.g.
  /// an rc file blocking on stdin) can hang the child indefinitely; when that
  /// happens we terminate the process so `waitUntilExit` cannot pin the
  /// cooperative pool thread.
  private static let versionCommandTimeoutSeconds: UInt64 = 5

  let homeDirectoryURL: URL
  let fileManager: FileManager
  let runKiroVersionCommand: @Sendable () async throws -> CommandResult

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.init(
      homeDirectoryURL: homeDirectoryURL,
      fileManager: fileManager,
      runKiroVersionCommand: Self.runKiroVersionCommand
    )
  }

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    runKiroVersionCommand: @escaping @Sendable () async throws -> CommandResult
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
    self.runKiroVersionCommand = runKiroVersionCommand
  }

  func isInstalled(progress: Bool) -> Bool {
    let entries: [String: [JSONValue]]
    do {
      entries =
        try progress
        ? KiroHookSettings.progressHookEntriesByEvent()
        : KiroHookSettings.notificationHookEntriesByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error, progress: progress)
      return false
    }
    return fileInstaller.containsMatchingHooks(
      settingsURL: settingsURL,
      hookEntriesByEvent: entries
    )
  }

  func installProgressHooks() async throws {
    try await ensureDefaultAgentConfig()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.progressHookEntriesByEvent()
    )
  }

  func installNotificationHooks() async throws {
    try await ensureDefaultAgentConfig()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.notificationHookEntriesByEvent()
    )
  }

  func uninstallProgressHooks() throws {
    guard fileManager.fileExists(atPath: settingsURL.path) else { return }
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.progressHookEntriesByEvent()
    )
  }

  func uninstallNotificationHooks() throws {
    guard fileManager.fileExists(atPath: settingsURL.path) else { return }
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookEntriesByEvent: try KiroHookSettings.notificationHookEntriesByEvent()
    )
  }

  // MARK: - Default agent config.

  /// Creates `kiro_default.json` with the known built-in defaults when the file does not exist.
  /// Creating this file overrides Kiro's built-in agent entirely, so we must include the full
  /// config (not just hooks) — and we gate on `supportedVersionPrefix` so a future Kiro release
  /// that ships different defaults fails loudly instead of being silently stomped.
  private func ensureDefaultAgentConfig() async throws {
    guard !fileManager.fileExists(atPath: settingsURL.path) else { return }
    try await validateSupportedKiroVersion()
    try fileManager.createDirectory(
      at: settingsURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let defaultConfig: [String: JSONValue] = [
      "name": .string("kiro_default"),
      "tools": .array([.string("*")]),
      "resources": .array([
        .string("file://AGENTS.md"),
        .string("file://README.md"),
        .string("skill://~/.kiro/skills/**/SKILL.md"),
        .string("skill://~/.kiro/steering/**/*.md"),
      ]),
      "useLegacyMcpJson": .bool(true),
      "hooks": .object([:]),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(JSONValue.object(defaultConfig))
    try data.write(to: settingsURL, options: .atomic)
  }

  private func validateSupportedKiroVersion() async throws {
    let result: CommandResult
    do {
      result = try await runKiroVersionCommand()
    } catch {
      kiroVersionLogger.warning("Kiro version check failed to execute: \(error)")
      throw KiroSettingsInstallerError.kiroUnavailable
    }
    if result.status == 127 {
      throw KiroSettingsInstallerError.kiroUnavailable
    }
    if result.status != 0 {
      kiroVersionLogger.warning(
        "Kiro version check exited with status \(result.status); stderr: \(result.standardError)")
      throw KiroSettingsInstallerError.unsupportedKiroVersion("exit status \(result.status)")
    }
    // Parse stdout first so a verbose login shell (rc-file banners on stderr)
    // cannot hijack the version match.
    let detected =
      Self.extractVersion(from: result.standardOutput)
      ?? Self.extractVersion(from: result.standardError)
    guard let detected else {
      kiroVersionLogger.warning(
        "Kiro version output unparseable; stdout: \(result.standardOutput)")
      throw KiroSettingsInstallerError.unsupportedKiroVersion(
        result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
    guard Self.isSupportedVersion(detected) else {
      throw KiroSettingsInstallerError.unsupportedKiroVersion(detected)
    }
  }

  /// Returns `true` when `detected`'s first dot-delimited component matches
  /// `supportedVersionPrefix` (after stripping its trailing dot). `"1."` matches
  /// `1.2.3` but not `10.0` — `10` is its own component, not "starts-with 1".
  static func isSupportedVersion(_ detected: String) -> Bool {
    let prefix = Self.supportedVersionPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let components = detected.split(separator: ".", omittingEmptySubsequences: false)
    return components.first.map(String.init) == prefix
  }

  /// Pulls the first dotted-digit token out of a version string such as
  /// `kiro 1.2.3` or `Kiro CLI v1.0.0 (build abcd)`.
  static func extractVersion(from text: String) -> String? {
    var current = ""
    for character in text {
      if character.isNumber || character == "." {
        current.append(character)
        continue
      }
      if current.contains(".") {
        return current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
      }
      current = ""
    }
    guard current.contains(".") else { return nil }
    return current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }

  // MARK: - Paths.

  private var settingsURL: URL {
    Self.settingsURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func settingsURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".kiro", isDirectory: true)
      .appendingPathComponent("agents", isDirectory: true)
      .appendingPathComponent("kiro_default.json", isDirectory: false)
  }

  static func runKiroVersionCommand() async throws -> CommandResult {
    let process = Process()
    process.executableURL = CodexSettingsInstaller.loginShellURL()
    process.arguments = ["-l", "-c", "kiro --version"]
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()

    let watchdog = Task { [process] in
      try? await Task.sleep(nanoseconds: versionCommandTimeoutSeconds * 1_000_000_000)
      if process.isRunning {
        kiroVersionLogger.warning(
          "kiro --version exceeded \(versionCommandTimeoutSeconds)s; terminating.")
        process.terminate()
      }
    }
    defer { watchdog.cancel() }

    // Drain both pipes concurrently; a verbose login shell (banners from
    // rc files under `-l`) can exceed the ~64KB pipe buffer and deadlock
    // the child on write if we wait for termination before reading.
    async let outputData = Self.readDataToEnd(from: outputPipe.fileHandleForReading)
    async let errorData = Self.readDataToEnd(from: errorPipe.fileHandleForReading)
    let standardOutputData = await outputData
    let standardErrorData = await errorData
    process.waitUntilExit()

    let standardOutput = Self.decodeUTF8(standardOutputData, descriptor: "stdout")
    let standardError = Self.decodeUTF8(standardErrorData, descriptor: "stderr")
    return .init(
      status: process.terminationStatus,
      standardOutput: standardOutput,
      standardError: standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Reads a file handle to EOF on a detached Task so `async let` callers can
  /// drain stdout and stderr concurrently while the child is still writing.
  ///
  /// NOTE: if the parent Task is cancelled mid-await, the detached reader
  /// stays alive until the pipe closes (child exits). Acceptable for a
  /// one-shot version probe — do not copy this into a streaming path.
  private static func readDataToEnd(from handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      Task.detached {
        continuation.resume(returning: handle.readDataToEndOfFile())
      }
    }
  }

  private static func decodeUTF8(_ data: Data, descriptor: String) -> String {
    if let string = String(data: data, encoding: .utf8) { return string }
    if !data.isEmpty {
      kiroVersionLogger.warning(
        "Kiro version \(descriptor) was not valid UTF-8 (\(data.count) bytes); dropped.")
    }
    return ""
  }

  private static func reportInvalidHookConfiguration(_ error: Error, progress: Bool) {
    #if DEBUG
      assertionFailure(
        "Kiro \(progress ? "progress" : "notification") hook configuration is invalid: \(error)")
    #endif
  }

  private var fileInstaller: KiroHookSettingsFileInstaller {
    KiroHookSettingsFileInstaller(
      fileManager: fileManager,
      errors: .init(
        invalidEventHooks: { KiroSettingsInstallerError.invalidEventHooks($0) },
        invalidHooksObject: { KiroSettingsInstallerError.invalidHooksObject },
        invalidJSON: { KiroSettingsInstallerError.invalidJSON($0) },
        invalidRootObject: { KiroSettingsInstallerError.invalidRootObject }
      )
    )
  }
}

nonisolated enum KiroSettingsInstallerError: Error, Equatable, LocalizedError {
  case invalidEventHooks(String)
  case invalidHooksObject
  case invalidJSON(String)
  case invalidRootObject
  case kiroUnavailable
  case unsupportedKiroVersion(String)

  var errorDescription: String? {
    switch self {
    case .invalidEventHooks(let event):
      "Kiro agent config uses an unsupported hooks shape for \(event)."
    case .invalidHooksObject:
      "Kiro agent config uses an unsupported hooks shape."
    case .invalidJSON(let detail):
      "Kiro agent config must be valid JSON before Supacode can install hooks (\(detail))."
    case .invalidRootObject:
      "Kiro agent config must be a JSON object before Supacode can install hooks."
    case .kiroUnavailable:
      "Kiro must be installed and available in your login shell before Supacode can install hooks."
    case .unsupportedKiroVersion(let detected):
      """
      Supacode only knows Kiro \(KiroSettingsInstaller.supportedVersionPrefix)x defaults \
      (detected \(detected.isEmpty ? "unknown" : detected)). Update Supacode before installing hooks.
      """
    }
  }
}
