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
    let name = repositoryDirectoryName(for: rootURL)
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  static func normalizedWorktreeBaseDirectoryPath(
    _ rawPath: String?,
    repositoryRootURL: URL? = nil
  ) -> String? {
    guard let rawPath else {
      return nil
    }
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    let directoryURL: URL
    if expanded.hasPrefix("/") {
      directoryURL = URL(filePath: expanded, directoryHint: .isDirectory)
    } else if let repositoryRootURL {
      directoryURL = repositoryRootURL.standardizedFileURL
        .appending(path: expanded, directoryHint: .isDirectory)
    } else {
      directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: expanded, directoryHint: .isDirectory)
    }
    return directoryURL.standardizedFileURL.path(percentEncoded: false)
  }

  static func worktreeBaseDirectory(
    for repositoryRootURL: URL,
    globalDefaultPath: String?,
    repositoryOverridePath: String?
  ) -> URL {
    let rootURL = repositoryRootURL.standardizedFileURL
    if let repositoryOverridePath = normalizedWorktreeBaseDirectoryPath(
      repositoryOverridePath,
      repositoryRootURL: rootURL
    ) {
      return URL(filePath: repositoryOverridePath, directoryHint: .isDirectory).standardizedFileURL
    }
    if let globalDefaultPath = normalizedWorktreeBaseDirectoryPath(globalDefaultPath) {
      return URL(filePath: globalDefaultPath, directoryHint: .isDirectory)
        .standardizedFileURL
        .appending(path: repositoryDirectoryName(for: rootURL), directoryHint: .isDirectory)
        .standardizedFileURL
    }
    return repositoryDirectory(for: rootURL)
  }

  static func exampleWorktreePath(
    for repositoryRootURL: URL,
    globalDefaultPath: String?,
    repositoryOverridePath: String?,
    branchName: String = "swift-otter"
  ) -> String {
    worktreeBaseDirectory(
      for: repositoryRootURL,
      globalDefaultPath: globalDefaultPath,
      repositoryOverridePath: repositoryOverridePath
    )
    .appending(path: branchName, directoryHint: .isDirectory)
    .standardizedFileURL
    .path(percentEncoded: false)
  }

  static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }

  static func repositorySettingsURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.appending(path: "supacode.json", directoryHint: .notDirectory)
  }

  private static func repositoryDirectoryName(for rootURL: URL) -> String {
    let repoName = rootURL.lastPathComponent
    if repoName.isEmpty || repoName == ".bare" || repoName == ".git" {
      let path = rootURL.standardizedFileURL.path(percentEncoded: false)
      let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if trimmed.isEmpty {
        return "_"
      }
      return trimmed.replacing("/", with: "_")
    }
    return repoName
  }
}
