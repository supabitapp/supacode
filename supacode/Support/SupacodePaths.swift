import Foundation

nonisolated enum SupacodePaths {
  static var baseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".supacode", directoryHint: .isDirectory)
  }

  static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  static var socketPath: String {
    baseDirectory
      .appending(path: "run/api.sock", directoryHint: .notDirectory)
      .path(percentEncoded: false)
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
