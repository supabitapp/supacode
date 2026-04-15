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
  case .intellij, .webstorm, .pycharm, .rustrover:
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
    .kitty, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders, .vscodium,
    .warp, .wezterm, .windsurf, .xcode, .zed:
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(
        OpenActionError(
          title: "\(action.title) not found",
          message: "Install \(action.title) to open this worktree."
        )
      )
      return
    }
    NSWorkspace.shared.open(
      [worktree.workingDirectory],
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
