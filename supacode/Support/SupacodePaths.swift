import Foundation

nonisolated enum SupacodePaths {
  static var baseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".supacode", directoryHint: .isDirectory)
  }

  static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  static func repositoryDirectory(for rootURL: URL, configuredName: String?) -> URL {
    let resolvedRootURL = rootURL.standardizedFileURL
    let fallback = resolvedRootURL.path(percentEncoded: false).replacing("/", with: "_")
    let candidate = Repository.directoryName(
      for: resolvedRootURL,
      configuredName: configuredName
    )
    let name = Repository.isValidDirectoryName(candidate) ? candidate : fallback
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }
}
