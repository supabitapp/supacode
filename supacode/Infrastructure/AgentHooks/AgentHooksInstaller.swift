import Foundation

nonisolated enum AgentHooksInstaller {
  nonisolated(unsafe) static var baseDirectoryOverride: URL?
  nonisolated(unsafe) static var resourceDirectoryOverride: URL?
  nonisolated(unsafe) static var signalsDirectoryOverride: URL?

  static var hooksDirectory: URL {
    let baseDirectory = baseDirectoryOverride ?? SupacodePaths.baseDirectory
    return baseDirectory.appending(path: "hooks", directoryHint: .isDirectory)
  }

  static var binDirectory: URL {
    hooksDirectory.appending(path: "bin", directoryHint: .isDirectory)
  }

  static var runtimeDirectory: URL {
    if let signalsDirectoryOverride {
      return signalsDirectoryOverride.deletingLastPathComponent()
    }
    if let baseDirectoryOverride {
      return baseDirectoryOverride
    }
    return SupacodePaths.resolvedTemporaryDirectory(appending: "supacode-agent-hooks")
  }

  static var signalsDirectory: URL {
    if let signalsDirectoryOverride {
      return signalsDirectoryOverride
    }
    return runtimeDirectory.appending(path: "signals", directoryHint: .isDirectory)
  }

  static var logFileURL: URL {
    runtimeDirectory.appending(path: "hooks.log", directoryHint: .notDirectory)
  }

  static var isInstalled: Bool {
    FileManager.default.fileExists(atPath: binDirectory.path(percentEncoded: false))
  }

  static func synchronize(claudeEnabled: Bool, codexEnabled: Bool) throws {
    if !claudeEnabled && !codexEnabled {
      try uninstall()
      return
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: signalsDirectory, withIntermediateDirectories: true)

    try synchronizeNotifyScript()
    try synchronizeClaudeFiles(enabled: claudeEnabled)
    try synchronizeCodexWrapper(enabled: codexEnabled)
  }

  static func uninstall() throws {
    let fileManager = FileManager.default
    let hooksPath = hooksDirectory.path(percentEncoded: false)
    if fileManager.fileExists(atPath: hooksPath) {
      try fileManager.removeItem(at: hooksDirectory)
    }
    let signalsPath = signalsDirectory.path(percentEncoded: false)
    if fileManager.fileExists(atPath: signalsPath) {
      try fileManager.removeItem(at: signalsDirectory)
    }
  }

  private static func synchronizeNotifyScript() throws {
    let sourceURL = try resourceURL(named: "notify.sh")
    let destinationURL = hooksDirectory.appending(path: "notify.sh", directoryHint: .notDirectory)
    try copyFile(from: sourceURL, to: destinationURL)
    try makeExecutable(destinationURL)
  }

  private static func synchronizeClaudeFiles(enabled: Bool) throws {
    let wrapperURL = binDirectory.appending(path: "claude", directoryHint: .notDirectory)
    let settingsURL = hooksDirectory.appending(path: "claude-settings.json", directoryHint: .notDirectory)

    guard enabled else {
      try removeIfExists(wrapperURL)
      try removeIfExists(settingsURL)
      return
    }

    let wrapperSourceURL = try resourceURL(named: "claude-wrapper.sh")
    try copyFile(from: wrapperSourceURL, to: wrapperURL)
    try makeExecutable(wrapperURL)

    let templateURL = try resourceURL(named: "claude-settings-template.json")
    let templateData = try Data(contentsOf: templateURL)
    guard var template = String(data: templateData, encoding: .utf8) else {
      throw AgentHooksInstallerError.invalidTemplate
    }
    let notifyPath =
      hooksDirectory
      .appending(path: "notify.sh", directoryHint: .notDirectory)
      .path(percentEncoded: false)
    template = template.replacing("__NOTIFY_PATH__", with: jsonEscaped(notifyPath))
    guard let renderedData = template.data(using: .utf8) else {
      throw AgentHooksInstallerError.invalidTemplate
    }
    try renderedData.write(to: settingsURL, options: .atomic)
  }

  private static func synchronizeCodexWrapper(enabled: Bool) throws {
    let wrapperURL = binDirectory.appending(path: "codex", directoryHint: .notDirectory)

    guard enabled else {
      try removeIfExists(wrapperURL)
      return
    }

    let wrapperSourceURL = try resourceURL(named: "codex-wrapper.sh")
    try copyFile(from: wrapperSourceURL, to: wrapperURL)
    try makeExecutable(wrapperURL)
  }

  private static func resourceURL(named name: String) throws -> URL {
    if let resourceDirectoryOverride {
      return resourceDirectoryOverride.appending(path: name, directoryHint: .notDirectory)
    }
    guard let resourceDirectory = Bundle.main.resourceURL?.appending(path: "hooks", directoryHint: .isDirectory)
    else {
      throw AgentHooksInstallerError.missingResource(name)
    }
    return resourceDirectory.appending(path: name, directoryHint: .notDirectory)
  }

  private static func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    let sourcePath = sourceURL.path(percentEncoded: false)
    let destinationPath = destinationURL.path(percentEncoded: false)

    guard fileManager.fileExists(atPath: sourcePath) else {
      throw AgentHooksInstallerError.missingResource(sourcePath)
    }

    if fileManager.fileExists(atPath: destinationPath) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
  }

  private static func removeIfExists(_ url: URL) throws {
    let fileManager = FileManager.default
    let path = url.path(percentEncoded: false)
    if fileManager.fileExists(atPath: path) {
      try fileManager.removeItem(at: url)
    }
  }

  private static func makeExecutable(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path(percentEncoded: false)
    )
  }

  private static func jsonEscaped(_ value: String) -> String {
    value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
  }
}

nonisolated enum AgentHooksInstallerError: Error, Equatable {
  case missingResource(String)
  case invalidTemplate
}
