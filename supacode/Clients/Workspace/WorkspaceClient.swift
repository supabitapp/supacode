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
    if worktree.host != nil {
      WorktreeOpener.performRemote(action: action, worktree: worktree, onError: onError)
    } else {
      WorktreeOpener.perform(action: action, worktree: worktree, onError: onError)
    }
  }

  static let testValue = WorkspaceClient { _, _, _ in }
}

extension DependencyValues {
  var workspaceClient: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}

@MainActor
enum WorktreeOpener {
  static func perform(
    action: OpenWorktreeAction,
    worktree: Worktree,
    onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
  ) {
    guard action != .editor else {
      return
    }
    guard let targetURL = WorkspaceOpenResolver.resolveFirstTarget(for: action.openTargets, worktree: worktree) else {
      onError(
        OpenActionError(
          title: "Unable to open in \(action.title)",
          message: "No matching target was found for this worktree."
        )
      )
      return
    }
    guard action != .finder else {
      NSWorkspace.shared.activateFileViewerSelecting([targetURL])
      return
    }
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) else {
      onError(.appNotFound(action))
      return
    }
    for behavior in action.openBehaviors {
      switch behavior {
      case .workspace(let configuration):
        openWithWorkspace(
          action: action,
          configuration: configuration,
          appURL: appURL,
          targetURL: targetURL,
          onError: onError
        )
        return
      case .process(let executable, let args):
        switch openWithProcess(executable: executable, args: args, appURL: appURL, targetURL: targetURL) {
        case .launched:
          return
        case .unavailable:
          continue
        case .failed(let error):
          onError(.openFailed(action, error))
          return
        }
      }
    }
    onError(
      OpenActionError(
        title: "Unable to open in \(action.title)",
        message: "No supported open behavior was available for this worktree."
      )
    )
  }

  /// The pre-launch outcome for a remote open: the process to run, or the error
  /// to surface. Pure (no `Process` / AppKit), so the guards are unit-testable.
  enum RemoteLaunchPlan: Equatable {
    case run(executableURL: URL, arguments: [String])
    case failure(OpenActionError)
  }

  /// Decides how to open `action` on `host` at `remotePath` for the resolved
  /// `appURL` (`nil` means not installed). Unlike `perform`, there is no local
  /// fallback: the editor's Remote-SSH CLI is required. The reducer pre-gates
  /// capability; the guards here are defensive.
  static func remoteLaunchPlan(
    action: OpenWorktreeAction,
    host: RemoteHost,
    remotePath: String,
    appURL: URL?,
    fileManager: FileManager = .default
  ) -> RemoteLaunchPlan {
    guard let invocation = action.remoteOpenInvocation(host: host, remotePath: remotePath) else {
      return .failure(
        OpenActionError(
          title: "Can't open in \(action.title)",
          message: "\(action.title) doesn't support opening remote SSH worktrees."
        )
      )
    }
    guard let appURL else {
      return .failure(.appNotFound(action))
    }
    guard let resolved = processInvocation(executable: invocation.executable, appURL: appURL, fileManager: fileManager)
    else {
      return .failure(
        OpenActionError(
          title: "Unable to open in \(action.title)",
          message:
            "\(action.title)'s command-line tool is required to open remote worktrees but wasn't found."
        )
      )
    }
    return .run(executableURL: resolved.executableURL, arguments: resolved.argumentPrefix + invocation.arguments)
  }

  /// Opens a remote SSH worktree via the editor's Remote-SSH CLI: resolve the
  /// app, defer the decision to the pure `remoteLaunchPlan`, then launch or
  /// surface its error.
  static func performRemote(
    action: OpenWorktreeAction,
    worktree: Worktree,
    onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
  ) {
    guard let host = worktree.host else {
      return
    }
    let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier)
    switch remoteLaunchPlan(
      action: action,
      host: host,
      remotePath: worktree.location.workingDirectoryPath,
      appURL: appURL
    ) {
    case .failure(let error):
      onError(error)
    case .run(let executableURL, let arguments):
      let process = Process()
      process.executableURL = executableURL
      process.arguments = arguments
      do {
        try process.run()
      } catch {
        onError(.remoteLaunchFailed(action, error))
      }
    }
  }

  private enum BehaviorOpenResult {
    case launched
    case unavailable
    case failed(Error)
  }

  private static func openWithWorkspace(
    action: OpenWorktreeAction,
    configuration: OpenBehavior.WorkspaceConfiguration?,
    appURL: URL,
    targetURL: URL,
    onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
  ) {
    let workspaceConfiguration = workspaceOpenConfiguration(
      configuration,
      appURL: appURL,
      targetURL: targetURL
    )
    guard configuration?.arguments.isEmpty == false else {
      openTargetWithWorkspace(
        action: action,
        configuration: workspaceConfiguration,
        appURL: appURL,
        targetURL: targetURL,
        onError: onError
      )
      return
    }
    NSWorkspace.shared.openApplication(at: appURL, configuration: workspaceConfiguration) { _, error in
      guard let error else {
        return
      }
      Task { @MainActor in
        onError(.openFailed(action, error))
      }
    }
  }

  private static func openTargetWithWorkspace(
    action: OpenWorktreeAction,
    configuration: NSWorkspace.OpenConfiguration,
    appURL: URL,
    targetURL: URL,
    onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
  ) {
    NSWorkspace.shared.open(
      [targetURL],
      withApplicationAt: appURL,
      configuration: configuration
    ) { _, error in
      guard let error else {
        return
      }
      Task { @MainActor in
        onError(.openFailed(action, error))
      }
    }
  }

  private static func openWithProcess(
    executable: OpenBehavior.ProcessExecutable,
    args: [OpenBehavior.Argument],
    appURL: URL,
    targetURL: URL
  ) -> BehaviorOpenResult {
    guard let invocation = processInvocation(executable: executable, appURL: appURL) else {
      return .unavailable
    }
    let process = Process()
    process.executableURL = invocation.executableURL
    process.arguments =
      invocation.argumentPrefix + args.map { resolvedOpenArgument($0, appURL: appURL, targetURL: targetURL) }
    do {
      try process.run()
      return .launched
    } catch {
      return .failed(error)
    }
  }

  static func processInvocation(
    executable: OpenBehavior.ProcessExecutable,
    appURL: URL,
    fileManager: FileManager = .default
  ) -> (executableURL: URL, argumentPrefix: [String])? {
    switch executable {
    case .appRelativePath(let relativePath):
      let executableURL = appRelativeURL(appURL: appURL, relativePath: relativePath)
      guard fileManager.fileExists(atPath: executableURL.path(percentEncoded: false)) else {
        return nil
      }
      return (executableURL, [])
    case .path(let path):
      if path.hasPrefix("/") {
        return (URL(fileURLWithPath: path), [])
      }
      return (URL(fileURLWithPath: "/usr/bin/env"), [path])
    }
  }

  private static func appRelativeURL(appURL: URL, relativePath: String) -> URL {
    relativePath.split(separator: "/", omittingEmptySubsequences: true).reduce(appURL) { url, component in
      url.appending(path: String(component))
    }
  }

  private static func workspaceOpenConfiguration(
    _ configuration: OpenBehavior.WorkspaceConfiguration?,
    appURL: URL,
    targetURL: URL
  ) -> NSWorkspace.OpenConfiguration {
    let workspaceConfiguration = NSWorkspace.OpenConfiguration()
    guard let configuration else {
      return workspaceConfiguration
    }
    workspaceConfiguration.createsNewApplicationInstance = configuration.createsNewApplicationInstance
    workspaceConfiguration.arguments = configuration.arguments.map {
      resolvedOpenArgument($0, appURL: appURL, targetURL: targetURL)
    }
    return workspaceConfiguration
  }

  private static func resolvedOpenArgument(
    _ argument: OpenBehavior.Argument,
    appURL: URL,
    targetURL: URL
  ) -> String {
    switch argument {
    case .literal(let value):
      value
    case .appPath:
      appURL.path(percentEncoded: false)
    case .targetPath:
      targetURL.path(percentEncoded: false)
    case .targetURL:
      targetURL.absoluteString
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

  /// Why a remote open was rejected before launch, so a hotkey / deeplink that
  /// bypasses the UI gates still tells the user why nothing opened.
  static func remoteOpenUnsupported(
    _ action: OpenWorktreeAction,
    host: RemoteHost,
    remotePath: String
  ) -> OpenActionError {
    if action == .finder {
      return OpenActionError(
        title: "Can't reveal remote worktree",
        message: "Reveal in Finder isn't available for remote SSH worktrees."
      )
    }
    let message =
      action.remoteOpenDisabledReason(host: host, remotePath: remotePath)
      ?? "\(action.title) doesn't support opening remote SSH worktrees."
    return OpenActionError(title: "Can't open in \(action.title)", message: message)
  }

  /// A launch failure is almost always the CLI being un-runnable, so name the
  /// editor and surface the underlying error for context.
  static func remoteLaunchFailed(_ action: OpenWorktreeAction, _ error: Error) -> OpenActionError {
    OpenActionError(
      title: "Unable to open in \(action.title)",
      message: "Couldn't launch \(action.title)'s command-line tool to open the remote worktree. "
        + error.localizedDescription
    )
  }
}

enum WorkspaceOpenResolver {
  static func resolveFirstTarget(
    for targets: [OpenTarget],
    worktree: Worktree,
    fileManager: FileManager = .default
  ) -> URL? {
    for target in targets {
      if let resolved = resolve(target, worktree: worktree, fileManager: fileManager) {
        return resolved
      }
    }
    return nil
  }

  private static func resolve(
    _ target: OpenTarget,
    worktree: Worktree,
    fileManager: FileManager
  ) -> URL? {
    switch target {
    case .workingDirectory:
      worktree.workingDirectory
    case .url(let url):
      url
    case .search(let pattern, let excludeDirectories, let maxDepth):
      search(
        in: worktree.workingDirectory,
        matching: pattern,
        excludeDirectories: excludeDirectories,
        maxDepth: maxDepth,
        fileManager: fileManager
      )
    }
  }

  private static func search(
    in rootURL: URL,
    matching pattern: String,
    excludeDirectories: String?,
    maxDepth: Int,
    fileManager: FileManager
  ) -> URL? {
    guard let targetRegex = try? Regex(pattern) else {
      return nil
    }
    let excludeRegex = excludeDirectories.flatMap { try? Regex($0) }
    guard maxDepth > 0 else {
      return nil
    }
    var directories = [SearchDirectory(url: rootURL, relativePath: "")]
    for depth in 1...maxDepth {
      let entries = directories.flatMap { directory in
        searchEntries(
          in: directory,
          fileManager: fileManager
        )
      }
      .sorted { lhs, rhs in
        lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
      }

      for entry in entries where matches(targetRegex, in: entry.relativePath) {
        return entry.url
      }

      directories = entries.compactMap { entry in
        guard depth < maxDepth, entry.isDirectory, !entry.isPackage else {
          return nil
        }
        if let excludeRegex, matches(excludeRegex, in: entry.relativePath) {
          return nil
        }
        return SearchDirectory(url: entry.url, relativePath: entry.relativePath)
      }
    }
    return nil
  }

  private struct SearchDirectory {
    let url: URL
    let relativePath: String
  }

  private struct SearchEntry {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let isPackage: Bool
  }

  private static func searchEntries(
    in directory: SearchDirectory,
    fileManager: FileManager
  ) -> [SearchEntry] {
    guard
      let childURLs = try? fileManager.contentsOfDirectory(
        at: directory.url,
        includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return childURLs.map { childURL in
      let relativePath = childRelativePath(directory: directory, childURL: childURL)
      let resourceValues = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
      return SearchEntry(
        url: childURL,
        relativePath: relativePath,
        isDirectory: resourceValues?.isDirectory ?? false,
        isPackage: resourceValues?.isPackage ?? false
      )
    }
  }

  private static func matches(_ regex: Regex<AnyRegexOutput>, in value: String) -> Bool {
    value.firstMatch(of: regex) != nil
  }

  private static func childRelativePath(directory: SearchDirectory, childURL: URL) -> String {
    guard !directory.relativePath.isEmpty else {
      return childURL.lastPathComponent
    }
    return directory.relativePath + "/" + childURL.lastPathComponent
  }
}
