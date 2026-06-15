import Foundation

public nonisolated enum Tty7Paths {
  /// Root for all app-owned state (`layouts.json`, `settings.json`,
  /// `sidebar.json`, `repos/`). Defaults to `~/.tty7`, but honors a
  /// `TTY7_HOME` env override so a second build (e.g. a dev build running
  /// alongside the installed app) keeps an isolated state dir instead of
  /// clobbering the shared one — mirroring the `ZMX_DIR` socket-dir override.
  /// Unset for the release app + CLI + tests, so their behavior is unchanged.
  public static var baseDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["TTY7_HOME"],
      !override.isEmpty
    {
      return URL(filePath: override, directoryHint: .isDirectory)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".tty7", directoryHint: .isDirectory)
  }

  /// One-time migration from a pre-rename state dir to `~/.tty7` so an
  /// existing install keeps its layouts / settings / sidebar / repos across
  /// the app's rename history (`~/.supacode` → `~/.amux` → `~/.tty7`). Moves
  /// the most recent legacy dir that exists. No-op when a `TTY7_HOME` override
  /// is set (e.g. an isolated dev build), when `~/.tty7` already exists, or
  /// when there's nothing to migrate. Call once at launch before any persisted
  /// state is read.
  public static func migrateLegacyStateDirectoryIfNeeded() {
    guard ProcessInfo.processInfo.environment["TTY7_HOME"]?.isEmpty ?? true else { return }
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    let current = home.appending(path: ".tty7", directoryHint: .isDirectory)
    guard !fileManager.fileExists(atPath: current.path(percentEncoded: false)) else { return }
    // Most recent name first so the freshest state wins if several exist.
    for legacyName in [".amux", ".supacode"] {
      let legacy = home.appending(path: legacyName, directoryHint: .isDirectory)
      guard fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else { continue }
      try? fileManager.moveItem(at: legacy, to: current)
      return
    }
  }

  public static var reposDirectory: URL {
    baseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  public static func repositoryDirectory(for rootURL: URL) -> URL {
    let name = repositoryDirectoryName(for: rootURL)
    return reposDirectory.appending(path: name, directoryHint: .isDirectory)
  }

  public static func normalizedWorktreeBaseDirectoryPath(
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

  public static func worktreeBaseDirectory(
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

  /// Resolves an explicit worktree directory from the dialog's optional name /
  /// path overrides. Returns `nil` when neither is set so callers keep `wt`'s
  /// default `base/<branch>` placement (including nested slashes). The path
  /// override sets the parent directory (default: the resolved base); the name
  /// override sets the leaf folder (default: the branch name).
  public static func resolvedWorktreeDirectory(
    defaultBaseDirectory: URL,
    repositoryRootURL: URL,
    nameOverride: String?,
    pathOverride: String?,
    branchName: String
  ) -> URL? {
    let trimmedName = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedPath = pathOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedName.isEmpty || !trimmedPath.isEmpty else {
      return nil
    }
    return worktreePlacement(
      defaultBaseDirectory: defaultBaseDirectory,
      repositoryRootURL: repositoryRootURL,
      trimmedName: trimmedName,
      trimmedPath: trimmedPath,
      branchName: branchName
    )
  }

  /// Always-concrete counterpart to `resolvedWorktreeDirectory` for the dialog's
  /// live destination preview. Falls back to the default base and branch name
  /// when the overrides are empty.
  public static func previewWorktreeDirectory(
    defaultBaseDirectory: URL,
    repositoryRootURL: URL,
    nameOverride: String?,
    pathOverride: String?,
    branchName: String
  ) -> URL {
    worktreePlacement(
      defaultBaseDirectory: defaultBaseDirectory,
      repositoryRootURL: repositoryRootURL,
      trimmedName: nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      trimmedPath: pathOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      branchName: branchName
    )
  }

  /// Shared base + leaf join for both resolvers. `trimmedName` / `trimmedPath`
  /// are expected pre-trimmed by callers; only the branch-name fallback is
  /// re-trimmed defensively.
  private static func worktreePlacement(
    defaultBaseDirectory: URL,
    repositoryRootURL: URL,
    trimmedName: String,
    trimmedPath: String,
    branchName: String
  ) -> URL {
    let baseURL: URL
    if let normalizedPath = normalizedWorktreeBaseDirectoryPath(
      trimmedPath,
      repositoryRootURL: repositoryRootURL
    ) {
      baseURL = URL(filePath: normalizedPath, directoryHint: .isDirectory).standardizedFileURL
    } else {
      baseURL = defaultBaseDirectory.standardizedFileURL
    }
    let leaf =
      trimmedName.isEmpty
      ? branchName.trimmingCharacters(in: .whitespacesAndNewlines)
      : trimmedName
    guard !leaf.isEmpty else {
      return baseURL
    }
    return baseURL.appending(path: leaf, directoryHint: .isDirectory).standardizedFileURL
  }

  public static func exampleWorktreePath(
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

  public static var layoutsURL: URL {
    baseDirectory.appending(path: "layouts.json", directoryHint: .notDirectory)
  }

  public static var settingsURL: URL {
    baseDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
  }

  public static var sidebarURL: URL {
    baseDirectory.appending(path: "sidebar.json", directoryHint: .notDirectory)
  }

  public static func repositorySettingsURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.appending(path: "tty7.json", directoryHint: .notDirectory)
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
