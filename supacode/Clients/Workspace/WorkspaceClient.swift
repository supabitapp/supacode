import AppKit
import ComposableArchitecture
import SupacodeSettingsShared

struct WorkspaceClient {
  var open:
    @MainActor @Sendable (
      _ action: OpenWorktreeAction,
      _ worktree: Worktree,
      _ onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
    ) -> Void
}

extension WorkspaceClient: DependencyKey {
  static let liveValue = WorkspaceClient { action, worktree, onError in
    performOpenWorktreeAction(action: action, worktree: worktree, onError: onError)
  }

  static let testValue = WorkspaceClient { _, _, _ in }
}

extension DependencyValues {
  var workspaceClient: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}

private func performOpenWorktreeAction(
  action: OpenWorktreeAction,
  worktree: Worktree,
  onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
) {
  let actionTitle = action.title
  switch action {
  case .editor:
    return
  case .finder:
    NSWorkspace.shared.activateFileViewerSelecting([worktree.workingDirectory])
  case .androidStudio, .intellij, .webstorm, .pycharm, .rubymine, .rustrover:
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(
        OpenActionError(
          title: "\(action.title) not found",
          message: "Install \(action.title) to open this worktree."
        )
      )
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = [worktree.workingDirectory.path]
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
      guard let error else {
        return
      }
      Task { @MainActor in
        onError(
          OpenActionError(
            title: "Unable to open in \(actionTitle)",
            message: error.localizedDescription
          )
        )
      }
    }
  case .alacritty, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken, .gitup, .ghostty,
    .kitty, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders,
    .vscodium, .warp, .wezterm, .windsurf, .xcode, .zed:
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(
        OpenActionError(
          title: "\(action.title) not found",
          message: "Install \(action.title) to open this worktree."
        )
      )
      return
    }
    var targetURL = worktree.workingDirectory
    if case .xcode = action {
      targetURL = XcodeProjectLocator.findProject(in: worktree.workingDirectory) ?? worktree.workingDirectory
    }
    NSWorkspace.shared.open(
      [targetURL],
      withApplicationAt: appURL,
      configuration: .init()
    ) { _, error in
      guard let error else {
        return
      }
      Task { @MainActor in
        onError(
          OpenActionError(
            title: "Unable to open in \(actionTitle)",
            message: error.localizedDescription
          )
        )
      }
    }
  }
}

private enum XcodeProjectLocator {
  private static let skippedDirectoryNames = Set([
    ".build",
    ".dart_tool",
    ".expo",
    ".expo-shared",
    ".git",
    ".gradle",
    ".pnpm-store",
    ".swiftpm",
    ".symlinks",
    ".yarn",
    "Carthage",
    "DerivedData",
    "Pods",
    "build",
    "node_modules",
  ])

  static func findProject(in directory: URL, maxDepth: Int = 5) -> URL? {
    var directories = [directory.standardizedFileURL]

    for _ in 0..<maxDepth {
      var nextDirectories: [URL] = []
      var project: URL?

      for directory in directories.sorted(by: { $0.path < $1.path }) {
        for child in children(in: directory) {
          switch child.pathExtension {
          case "xcworkspace":
            return child
          case "xcodeproj":
            project = project ?? child
          default:
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
              continue
            }
            guard !skippedDirectoryNames.contains(child.lastPathComponent) else {
              continue
            }
            nextDirectories.append(child)
          }
        }
      }

      if let project {
        return project
      }
      directories = nextDirectories.sorted(by: { $0.path < $1.path })
    }

    return nil
  }

  private static func children(in directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    )) ?? [])
    .map(\.standardizedFileURL)
    .sorted(by: { $0.path < $1.path })
  }
}
