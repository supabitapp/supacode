import Foundation

nonisolated enum SupacodePaths {
  static var baseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".supacode", directoryHint: .isDirectory)
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

  static var temporaryDirectoryCandidates: [URL] {
    let fileManager = FileManager.default
    let candidates = [
      URL(filePath: "/tmp", directoryHint: .isDirectory),
      fileManager.temporaryDirectory,
    ]
    var seenPaths: Set<String> = []
    return candidates.filter { candidate in
      let path = candidate.standardizedFileURL.path(percentEncoded: false)
      return seenPaths.insert(path).inserted
    }
  }

  static func resolvedTemporaryDirectory(appending relativePath: String) -> URL {
    let fileManager = FileManager.default
    for baseURL in temporaryDirectoryCandidates {
      let directoryURL = baseURL.appending(path: relativePath, directoryHint: .isDirectory)
      do {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
      } catch {
        continue
      }
    }
    return fileManager.temporaryDirectory.appending(path: relativePath, directoryHint: .isDirectory)
  }
}
