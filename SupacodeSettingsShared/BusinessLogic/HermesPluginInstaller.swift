import Foundation

nonisolated enum HermesPluginInstallerError: Error {
  case pluginNotManaged
}

nonisolated struct HermesPluginInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
  }

  func installState() -> ComponentInstallState {
    guard
      let manifest = try? String(contentsOf: manifestFileURL, encoding: .utf8),
      let module = try? String(contentsOf: moduleFileURL, encoding: .utf8)
    else {
      return .notInstalled
    }
    if manifest == HermesPluginContent.manifest(), module == HermesPluginContent.module() { return .installed }
    return module.contains(HermesPluginContent.ownershipMarker) ? .outdated : .notInstalled
  }

  func install() throws {
    // Refuse to clobber a plugin Supacode doesn't own: auto-update calls this
    // unattended when the aggregate goes `.outdated`, and the path is a fixed
    // name a user's own plugin could occupy.
    if let module = try? String(contentsOf: moduleFileURL, encoding: .utf8),
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
    guard
      let module = try? String(contentsOf: moduleFileURL, encoding: .utf8),
      module.contains(HermesPluginContent.ownershipMarker)
    else {
      return
    }
    try fileManager.removeItem(at: pluginDirectoryURL)
  }

  var manifestFileURL: URL {
    pluginDirectoryURL.appendingPathComponent(HermesPluginContent.manifestFileName, isDirectory: false)
  }

  var moduleFileURL: URL {
    pluginDirectoryURL.appendingPathComponent(HermesPluginContent.moduleFileName, isDirectory: false)
  }

  var pluginDirectoryURL: URL {
    Self.pluginDirectoryURL(homeDirectoryURL: homeDirectoryURL)
  }

  static func pluginDirectoryURL(homeDirectoryURL: URL) -> URL {
    homeDirectoryURL
      .appendingPathComponent(".hermes", isDirectory: true)
      .appendingPathComponent("plugins", isDirectory: true)
      .appendingPathComponent(HermesPluginContent.pluginName, isDirectory: true)
  }
}
