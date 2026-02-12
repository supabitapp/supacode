import Foundation

nonisolated enum SupacodePaths {
  static let homeOverrideEnvironmentKey = "SUPACODE_HOME"
  static let homeOverrideUserDefaultsKey = "supacode.homeDirectoryOverride"

  static let cachedBaseDirectory: URL = resolveBaseDirectory(
    environment: ProcessInfo.processInfo.environment,
    persistedOverride: UserDefaults.standard.string(forKey: homeOverrideUserDefaultsKey),
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
  )

  static func defaultBaseDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    homeDirectory.appending(path: ".supacode", directoryHint: .isDirectory)
  }

  static func normalizedBaseDirectoryOverride(
    _ rawValue: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let expandedPath: String
    if trimmed == "~" {
      expandedPath = homeDirectory.path(percentEncoded: false)
    } else if trimmed.hasPrefix("~/") {
      let homePath = homeDirectory.path(percentEncoded: false)
      expandedPath = homePath + "/" + String(trimmed.dropFirst(2))
    } else {
      expandedPath = NSString(string: trimmed).expandingTildeInPath
    }
    guard expandedPath.hasPrefix("/") else {
      return nil
    }
    return URL(fileURLWithPath: expandedPath).standardizedFileURL
  }

  static func resolveBaseDirectory(
    environment: [String: String],
    persistedOverride: String?,
    homeDirectory: URL
  ) -> URL {
    if let environmentValue = environment[homeOverrideEnvironmentKey],
      let environmentOverride = normalizedBaseDirectoryOverride(environmentValue, homeDirectory: homeDirectory)
    {
      return environmentOverride
    }
    if let persistedOverride,
      let normalizedPersistedOverride = normalizedBaseDirectoryOverride(
        persistedOverride,
        homeDirectory: homeDirectory
      )
    {
      return normalizedPersistedOverride
    }
    return defaultBaseDirectory(homeDirectory: homeDirectory)
  }

  static var baseDirectory: URL {
    cachedBaseDirectory
  }

  static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  static func repositoryDirectory(for rootURL: URL) -> URL {
    let repoName = rootURL.lastPathComponent
    let fallback = rootURL.path(percentEncoded: false).replacing("/", with: "_")
    let name = repoName.isEmpty ? fallback : repoName
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }
}
