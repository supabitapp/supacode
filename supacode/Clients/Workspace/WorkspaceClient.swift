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
  case .alacritty, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken, .gitup, .ghostty,
    .kitty, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders,
    .vscodium, .warp, .wezterm, .windsurf, .xcode, .zed:
    AppLauncher.open(action: action, worktree: worktree, onError: onError)
  }
}

/// Opens a worktree directory in an arbitrary macOS app, preferring the app's bundled
/// command-line helper when it advertises one via `OpenWorktreeAction.cliLauncher`.
///
/// A CLI launch is preferred because it lets us pass flags/arguments the plain
/// "open document" event (`NSWorkspace.open`) cannot — e.g. Zed honoring
/// `cli_default_open_behavior` to give one window per worktree. Apps without a launcher,
/// and any app whose helper is missing, fall back to `NSWorkspace.open`.
enum AppLauncher {
  enum Plan: Equatable {
    case cli(executable: URL, arguments: [String])
    case workspaceOpen(url: URL)
  }

  static func plan(
    launcher: OpenWorktreeAction.CLILauncher?,
    appURL: URL,
    cliExists: Bool,
    workingDirectory: URL
  ) -> Plan {
    guard let launcher, cliExists else {
      return .workspaceOpen(url: workingDirectory)
    }
    return .cli(
      executable: appURL.appending(path: launcher.relativeExecutablePath),
      arguments: launcher.openArguments + [workingDirectory.path]
    )
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
    let launcher = action.cliLauncher
    let cliExists =
      launcher.map { FileManager.default.fileExists(atPath: appURL.appending(path: $0.relativeExecutablePath).path) }
      ?? false
    switch plan(
      launcher: launcher,
      appURL: appURL,
      cliExists: cliExists,
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

extension OpenWorktreeAction {
  /// Describes how to open a worktree through an app's bundled command-line helper.
  struct CLILauncher: Equatable {
    /// Path to the helper executable, relative to the app bundle root.
    let relativeExecutablePath: String
    /// Flags placed before the worktree path; the path is always appended last.
    let openArguments: [String]
  }

  /// The bundled CLI used to open a worktree, or `nil` to fall back to `NSWorkspace.open`.
  var cliLauncher: CLILauncher? {
    switch self {
    case .zed:
      // The bare path (no `-n`) gives one window per worktree when Zed's
      // `cli_default_open_behavior` is `new_window`, focusing an already-open worktree.
      CLILauncher(relativeExecutablePath: "Contents/MacOS/cli", openArguments: [])
    default:
      nil
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
