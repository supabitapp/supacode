import Foundation

nonisolated enum HermesPluginInstallerError: Error {
  case pluginNotManaged
}

nonisolated struct HermesPluginInstaller {
  let configDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    configDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.configDirectoryURL =
      configDirectoryURL ?? homeDirectoryURL.appending(path: ".hermes", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  func installState() throws -> ComponentInstallState {
    // Both files are probed: either one being unreadable makes the state
    // undeterminable, which is not the same as the plugin being absent.
    let manifest = try AgentFileProbe.text(at: manifestFileURL)
    let module = try AgentFileProbe.text(at: moduleFileURL)
    guard let manifest, let module else { return .notInstalled }
    if manifest == HermesPluginContent.manifest(), module == HermesPluginContent.module() { return .installed }
    return module.contains(HermesPluginContent.ownershipMarker) ? .outdated : .notInstalled
  }

  func install() throws {
    // Refuse to clobber a plugin Supacode doesn't own: auto-update calls this
    // unattended when the aggregate goes `.outdated`, and the path is a fixed
    // name a user's own plugin could occupy. Reading through the probe means an
    // unreadable module aborts rather than reading as "no marker".
    if let module = try AgentFileProbe.text(at: moduleFileURL),
      !module.contains(HermesPluginContent.ownershipMarker)
    {
      throw HermesPluginInstallerError.pluginNotManaged
    }
    try fileManager.createDirectory(at: pluginDirectoryURL, withIntermediateDirectories: true)
    do {
      try HermesPluginContent.manifest().write(to: manifestFileURL, atomically: true, encoding: .utf8)
      try HermesPluginContent.module().write(to: moduleFileURL, atomically: true, encoding: .utf8)
    } catch {
      // Never leave a manifest without its module: an orphaned plugin.yaml breaks Hermes at load.
      try? fileManager.removeItem(at: pluginDirectoryURL)
      throw error
    }
  }

  func uninstall() throws {
    // An unreadable module throws instead of reporting a removal that never
    // happened, leaving the row "not installed" with the plugin still loading.
    guard let module = try AgentFileProbe.text(at: moduleFileURL) else { return }
    guard module.contains(HermesPluginContent.ownershipMarker) else { return }
    try fileManager.removeItem(at: pluginDirectoryURL)
  }

  var manifestFileURL: URL {
    pluginDirectoryURL.appendingPathComponent(HermesPluginContent.manifestFileName, isDirectory: false)
  }

  var moduleFileURL: URL {
    pluginDirectoryURL.appendingPathComponent(HermesPluginContent.moduleFileName, isDirectory: false)
  }

  var pluginDirectoryURL: URL {
    configDirectoryURL
      .appending(path: "plugins", directoryHint: .isDirectory)
      .appending(path: HermesPluginContent.pluginName, directoryHint: .isDirectory)
  }

  static func pluginDirectoryURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".hermes", isDirectory: true)
      .appendingPathComponent("plugins", isDirectory: true)
      .appendingPathComponent(HermesPluginContent.pluginName, isDirectory: true)
  }
}
