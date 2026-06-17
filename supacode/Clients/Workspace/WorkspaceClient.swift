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
  switch action {
  case .editor:
    return
  case .finder:
    NSWorkspace.shared.activateFileViewerSelecting([worktree.workingDirectory])
  case .androidStudio, .intellij, .webstorm, .pycharm, .rubymine, .rustrover:
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(.appNotFound(action))
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
        onError(.openFailed(action, error))
      }
    }
  case .zed:
    ZedLaunch.open(action: action, worktree: worktree, onError: onError)
  case .alacritty, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken, .gitup, .ghostty,
    .kitty, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders,
    .vscodium, .warp, .wezterm, .windsurf, .xcode:
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(.appNotFound(action))
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
        onError(.openFailed(action, error))
      }
    }
  }
}

enum ZedLaunch {
  enum Plan: Equatable {
    case cli(executable: URL, arguments: [String])
    case workspaceOpen(url: URL)
  }

  static func cliURL(appURL: URL) -> URL {
    appURL.appending(path: "Contents/MacOS/cli")
  }

  /// Open the worktree through the bundled Zed CLI with the bare path (no `-n`), falling back
  /// to `NSWorkspace.open` only when the CLI helper is missing. With Zed's
  /// `cli_default_open_behavior` set to `new_window`, the bare path gives one window per
  /// worktree: a new window when the worktree isn't open yet, focus of the existing window when
  /// it is. `-n` is avoided because it forces a new window even for an already-open worktree,
  /// producing duplicates; `NSWorkspace.open` instead stacks every worktree into one window.
  static func plan(cliURL: URL, cliExists: Bool, workingDirectory: URL) -> Plan {
    cliExists
      ? .cli(executable: cliURL, arguments: [workingDirectory.path])
      : .workspaceOpen(url: workingDirectory)
  }

  @MainActor static func open(
    action: OpenWorktreeAction,
    worktree: Worktree,
    onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
  ) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(.appNotFound(action))
      return
    }
    let cliURL = cliURL(appURL: appURL)
    switch plan(
      cliURL: cliURL,
      cliExists: FileManager.default.fileExists(atPath: cliURL.path),
      workingDirectory: worktree.workingDirectory
    ) {
    case .cli(let executable, let arguments):
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      do {
        try process.run()
      } catch {
        onError(.openFailed(action, error))
      }
    case .workspaceOpen(let url):
      NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init()) { _, error in
        guard let error else {
          return
        }
        Task { @MainActor in
          onError(.openFailed(action, error))
        }
      }
    }
  }
}

extension OpenActionError {
  static func appNotFound(_ action: OpenWorktreeAction) -> OpenActionError {
    OpenActionError(
      title: "\(action.title) not found",
      message: "Install \(action.title) to open this worktree."
    )
  }

  static func openFailed(_ action: OpenWorktreeAction, _ error: Error) -> OpenActionError {
    OpenActionError(
      title: "Unable to open in \(action.title)",
      message: error.localizedDescription
    )
  }
}
