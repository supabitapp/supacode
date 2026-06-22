import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct OpenWorktreeActionTests {
  @Test func menuOrderIncludesExpectedWorkspaceActions() {
    let settingsIDs = OpenWorktreeAction.menuOrder.map(\.settingsID)

    #expect(settingsIDs.contains("android-studio"))
    #expect(settingsIDs.contains("antigravity"))
    #expect(settingsIDs.contains("intellij"))
    #expect(settingsIDs.contains("rubymine"))
    #expect(settingsIDs.contains("rustrover"))
    #expect(settingsIDs.contains("vscode-insiders"))
    #expect(settingsIDs.contains("warp"))
    #expect(settingsIDs.contains("webstorm"))
    #expect(settingsIDs.contains("pycharm"))
  }

  @Test func jetBrainsIDEsHaveCorrectBundleIdentifiers() {
    #expect(OpenWorktreeAction.androidStudio.bundleIdentifier == "com.google.android.studio")
    #expect(OpenWorktreeAction.intellij.bundleIdentifier == "com.jetbrains.intellij")
    #expect(OpenWorktreeAction.webstorm.bundleIdentifier == "com.jetbrains.WebStorm")
    #expect(OpenWorktreeAction.pycharm.bundleIdentifier == "com.jetbrains.pycharm")
    #expect(OpenWorktreeAction.rubymine.bundleIdentifier == "com.jetbrains.rubymine")
    #expect(OpenWorktreeAction.rustrover.bundleIdentifier == "com.jetbrains.rustrover")
  }

  @Test func jetBrainsIDEsAreInEditorPriority() {
    let editors = OpenWorktreeAction.editorPriority
    #expect(editors.contains(.androidStudio))
    #expect(editors.contains(.intellij))
    #expect(editors.contains(.webstorm))
    #expect(editors.contains(.pycharm))
    #expect(editors.contains(.rubymine))
    #expect(editors.contains(.rustrover))
  }

  @Test func xcodeOpenTargetsSearchWorkspaceThenProjectThenWorkingDirectory() {
    let targets = OpenWorktreeAction.xcode.openTargets

    #expect(targets.count == 3)
    guard case .search(let workspacePattern, let workspaceExclusions, let workspaceMaxDepth) = targets[0] else {
      #expect(Bool(false), "Xcode should search for workspaces first.")
      return
    }
    guard case .search(let projectPattern, let projectExclusions, let projectMaxDepth) = targets[1] else {
      #expect(Bool(false), "Xcode should search for projects second.")
      return
    }
    #expect(workspacePattern == #"\.xcworkspace$"#)
    for excludedDirectory in [
      #"\.build"#,
      #"\.dart_tool"#,
      #"\.expo"#,
      #"\.expo-shared"#,
      #"\.git"#,
      #"\.gradle"#,
      #"\.pnpm-store"#,
      #"\.swiftpm"#,
      #"\.symlinks"#,
      #"\.yarn"#,
      "Carthage",
      "DerivedData",
      "Pods",
      "build",
      "node_modules",
      #"\.xcodeproj"#,
      #"\.xcworkspace"#,
    ] {
      #expect(workspaceExclusions?.contains(excludedDirectory) == true)
    }
    #expect(workspaceMaxDepth == 3)
    #expect(projectPattern == #"\.xcodeproj$"#)
    #expect(projectExclusions == workspaceExclusions)
    #expect(projectMaxDepth == workspaceMaxDepth)
    #expect(targets[2] == .default)
    #expect(OpenTarget.default == .workingDirectory)
  }

  @Test func jetBrainsIDEsUseConfiguredWorkspaceOpenBehavior() {
    for action in [
      OpenWorktreeAction.androidStudio,
      .intellij,
      .webstorm,
      .pycharm,
      .rubymine,
      .rustrover,
    ] {
      guard action.openBehaviors.count == 1,
        case .workspace(let configuration) = action.openBehaviors[0],
        let configuration
      else {
        #expect(Bool(false), "\(action.title) should use workspace opening.")
        continue
      }
      #expect(configuration.createsNewApplicationInstance)
      #expect(configuration.arguments == [.targetPath])
    }
  }

  @Test func zedUsesBundledCLIThenWorkspaceOpenBehavior() {
    let behaviors = OpenWorktreeAction.zed.openBehaviors

    #expect(behaviors.count == 2)
    #expect(
      behaviors.first
        == .process(
          .appRelativePath("Contents/MacOS/cli"),
          args: [.targetPath]
        )
    )
    #expect(behaviors.last == .default)
    #expect(OpenBehavior.default == .workspace(configuration: nil))
  }

  @Test func zedPreviewUsesPreviewBundleIdentifierAndMirrorsZedOpenBehavior() {
    #expect(OpenWorktreeAction.zedPreview.bundleIdentifier == "dev.zed.Zed-Preview")
    #expect(OpenWorktreeAction.zedPreview.settingsID == "zed-preview")
    #expect(OpenWorktreeAction.zedPreview.title == "Zed Preview")
    #expect(OpenWorktreeAction.zedPreview.openBehaviors == OpenWorktreeAction.zed.openBehaviors)
  }

  @Test func zedPreviewIsAnEditorListedAfterZed() {
    let editors = OpenWorktreeAction.editorPriority
    #expect(editors.contains(.zedPreview))

    guard let zedIndex = editors.firstIndex(of: .zed),
      let previewIndex = editors.firstIndex(of: .zedPreview)
    else {
      #expect(Bool(false), "Both Zed channels should be in editor priority.")
      return
    }
    #expect(previewIndex == zedIndex + 1)
    #expect(OpenWorktreeAction.menuOrder.map(\.settingsID).contains("zed-preview"))
  }

  @MainActor
  @Test func appRelativeProcessExecutableResolvesOnlyWhenPresent() throws {
    let rootURL = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let appURL = rootURL.appending(path: "Zed.app")
    let cliURL = appURL.appending(path: "Contents/MacOS/cli")
    try FileManager.default.createDirectory(
      at: cliURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: cliURL.path(percentEncoded: false), contents: Data()))

    let present = WorktreeOpener.processInvocation(
      executable: .appRelativePath("Contents/MacOS/cli"),
      appURL: appURL
    )
    let missing = WorktreeOpener.processInvocation(
      executable: .appRelativePath("Contents/MacOS/missing"),
      appURL: appURL
    )

    #expect(Self.standardizedPath(present?.executableURL) == Self.standardizedPath(cliURL))
    #expect(present?.argumentPrefix == [])
    #expect(missing == nil)
  }

  @MainActor
  @Test func worktreeOpenerNoopsEditorAction() {
    var errors: [OpenActionError] = []

    WorktreeOpener.perform(
      action: .editor,
      worktree: Self.makeWorktree(at: URL(filePath: "/tmp/repo")),
      onError: { errors.append($0) }
    )

    #expect(errors.isEmpty)
  }

  @Test func resolverSkipsExcludedSearchDirectoriesAndFallsBackToNextTarget() throws {
    let rootURL = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "Pods/Generated.xcworkspace"),
      withIntermediateDirectories: true
    )
    let projectURL = rootURL.appending(path: "Supacode.xcodeproj")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

    let resolved = WorkspaceOpenResolver.resolveFirstTarget(
      for: [
        .search(#"\.xcworkspace$"#, excludeDirectories: #"(^|/)Pods(/|$)"#),
        .search(#"\.xcodeproj$"#, excludeDirectories: nil),
        .workingDirectory,
      ],
      worktree: Self.makeWorktree(at: rootURL)
    )

    #expect(Self.standardizedPath(resolved) == Self.standardizedPath(projectURL))
  }

  @Test func xcodeResolverDoesNotDescendIntoProjectPackages() throws {
    let rootURL = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let projectURL = rootURL.appending(path: "Supacode.xcodeproj")
    try FileManager.default.createDirectory(
      at: projectURL.appending(path: "project.xcworkspace"),
      withIntermediateDirectories: true
    )

    let resolved = WorkspaceOpenResolver.resolveFirstTarget(
      for: OpenWorktreeAction.xcode.openTargets,
      worktree: Self.makeWorktree(at: rootURL)
    )

    #expect(Self.standardizedPath(resolved) == Self.standardizedPath(projectURL))
  }

  @Test func xcodeResolverStillReturnsTopLevelWorkspacePackages() throws {
    let rootURL = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let workspaceURL = rootURL.appending(path: "Supacode.xcworkspace")
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "Supacode.xcodeproj/project.xcworkspace"),
      withIntermediateDirectories: true
    )

    let resolved = WorkspaceOpenResolver.resolveFirstTarget(
      for: OpenWorktreeAction.xcode.openTargets,
      worktree: Self.makeWorktree(at: rootURL)
    )

    #expect(Self.standardizedPath(resolved) == Self.standardizedPath(workspaceURL))
  }

  @Test func resolverOnlyUsesWorkingDirectoryWhenItIsAnExplicitFallback() throws {
    let rootURL = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let worktree = Self.makeWorktree(at: rootURL)

    let searchOnly = WorkspaceOpenResolver.resolveFirstTarget(
      for: [.search(#"\.xcworkspace$"#, excludeDirectories: nil)],
      worktree: worktree
    )
    let withExplicitFallback = WorkspaceOpenResolver.resolveFirstTarget(
      for: [.search(#"\.xcworkspace$"#, excludeDirectories: nil), .workingDirectory],
      worktree: worktree
    )

    #expect(searchOnly == nil)
    #expect(Self.standardizedPath(withExplicitFallback) == Self.standardizedPath(rootURL))
  }

  @Test func resolverHonorsSearchMaxDepth() throws {
    let rootURL = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let deepProjectURL = rootURL.appending(path: "Examples/macOS/App/Supacode.xcodeproj")
    try FileManager.default.createDirectory(at: deepProjectURL, withIntermediateDirectories: true)

    let defaultDepth = WorkspaceOpenResolver.resolveFirstTarget(
      for: [.search(#"\.xcodeproj$"#)],
      worktree: Self.makeWorktree(at: rootURL)
    )
    let deeperDepth = WorkspaceOpenResolver.resolveFirstTarget(
      for: [.search(#"\.xcodeproj$"#, maxDepth: 4)],
      worktree: Self.makeWorktree(at: rootURL)
    )

    #expect(defaultDepth == nil)
    #expect(Self.standardizedPath(deeperDepth) == Self.standardizedPath(deepProjectURL))
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "supacode-open-target-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func makeWorktree(at rootURL: URL) -> Worktree {
    Worktree(
      id: WorktreeID(rootURL.path(percentEncoded: false)),
      name: rootURL.lastPathComponent,
      detail: "detail",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
  }

  private static func standardizedPath(_ url: URL?) -> String? {
    url?.standardizedFileURL.path(percentEncoded: false)
  }
}
