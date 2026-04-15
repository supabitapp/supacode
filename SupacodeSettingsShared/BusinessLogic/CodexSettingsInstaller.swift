import Darwin
import Foundation

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

  func isInstalled(progress: Bool) -> Bool {
    let groups: [String: [JSONValue]]
    do {
      groups =
        try progress
        ? CodexHookSettings.progressHookGroupsByEvent()
        : CodexHookSettings.notificationHookGroupsByEvent()
    } catch {
      Self.reportInvalidHookConfiguration(error, progress: progress)
      return false
    }
    return fileInstaller.containsMatchingHooks(
      settingsURL: settingsURL,
      hookGroupsByEvent: groups
    )
  }

  func installProgressHooks() async throws {
    try await enableHooksFeature()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try CodexHookSettings.progressHookGroupsByEvent()
    )
  }

  func installNotificationHooks() async throws {
    try await enableHooksFeature()
    try fileInstaller.install(
      settingsURL: settingsURL,
      hookGroupsByEvent: try CodexHookSettings.notificationHookGroupsByEvent()
    )
  }

  func uninstallProgressHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try CodexHookSettings.progressHookGroupsByEvent()
    )
  }

  func uninstallNotificationHooks() throws {
    try fileInstaller.uninstall(
      settingsURL: settingsURL,
      hookGroupsByEvent: try CodexHookSettings.notificationHookGroupsByEvent()
    )
  }

  private func enableHooksFeature() async throws {
    let commandResult = try await runEnableHooksCommand()
    guard commandResult.status == 0 else {
      throw CodexSettingsInstallerError.enableHooksFailed(commandResult.standardError)
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
    process.arguments = ["-l", "-c", "codex features enable codex_hooks"]
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

  private static func reportInvalidHookConfiguration(_ error: Error, progress: Bool) {
    #if DEBUG
      assertionFailure("Codex \(progress ? "progress" : "notification") hook configuration is invalid: \(error)")
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
