import AppKit

public enum OpenTarget: Equatable, Sendable {
  case workingDirectory
  case url(URL)
  case search(String, excludeDirectories: String? = nil, maxDepth: Int = 3)

  public static let `default`: Self = .workingDirectory
}

public enum OpenBehavior: Equatable, Sendable {
  public struct WorkspaceConfiguration: Equatable, Sendable {
    public var createsNewApplicationInstance: Bool
    public var arguments: [Argument]

    public init(
      createsNewApplicationInstance: Bool = false,
      arguments: [Argument] = []
    ) {
      self.createsNewApplicationInstance = createsNewApplicationInstance
      self.arguments = arguments
    }
  }

  public enum ProcessExecutable: Equatable, Sendable {
    case path(String)
    case appRelativePath(String)
  }

  public enum Argument: Equatable, Sendable {
    case literal(String)
    case appPath
    case targetPath
    case targetURL
  }

  case workspace(configuration: WorkspaceConfiguration? = nil)
  case process(ProcessExecutable, args: [Argument])

  public static let `default`: Self = .workspace(configuration: nil)
}

public enum OpenWorktreeAction: CaseIterable, Identifiable {
  public enum MenuIcon {
    case app(NSImage)
    case symbol(String)
  }

  case alacritty
  case androidStudio
  case antigravity
  case editor
  case finder
  case cursor
  case githubDesktop
  case fork
  case gitkraken
  case gitup
  case ghostty
  case goland
  case intellij
  case intellijEAP
  case kitty
  case nova
  case pycharm
  case rider
  case rubymine
  case rustrover
  case smartgit
  case sourcetree
  case sublimeMerge
  case terminal
  case vscode
  case vscodeInsiders
  case vscodium
  case warp
  case webstorm
  case wezterm
  case windsurf
  case xcode
  case zed
  case zedPreview

  public var id: String { title }

  public var title: String {
    switch self {
    case .finder: "Reveal in Finder"
    case .editor: "$EDITOR"
    case .alacritty: "Alacritty"
    case .androidStudio: "Android Studio"
    case .antigravity: "Antigravity"
    case .cursor: "Cursor"
    case .githubDesktop: "GitHub Desktop"
    case .gitkraken: "GitKraken"
    case .gitup: "GitUp"
    case .ghostty: "Ghostty"
    case .goland: "GoLand"
    case .intellij: "IntelliJ IDEA"
    case .intellijEAP: "IntelliJ IDEA EAP"
    case .kitty: "Kitty"
    case .nova: "Nova"
    case .pycharm: "PyCharm"
    case .rider: "Rider"
    case .rubymine: "RubyMine"
    case .rustrover: "RustRover"
    case .smartgit: "SmartGit"
    case .sourcetree: "Sourcetree"
    case .sublimeMerge: "Sublime Merge"
    case .terminal: "Terminal"
    case .vscode: "VS Code"
    case .vscodeInsiders: "VS Code Insiders"
    case .vscodium: "VSCodium"
    case .warp: "Warp"
    case .wezterm: "WezTerm"
    case .webstorm: "WebStorm"
    case .windsurf: "Windsurf"
    case .xcode: "Xcode"
    case .fork: "Fork"
    case .zed: "Zed"
    case .zedPreview: "Zed Preview"
    }
  }

  public var labelTitle: String {
    switch self {
    case .finder: "Finder"
    case .editor: "$EDITOR"
    case .alacritty, .androidStudio, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken,
      .gitup, .ghostty, .goland, .intellij, .intellijEAP, .kitty, .nova, .pycharm, .rider, .rubymine,
      .rustrover, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders,
      .vscodium, .warp, .webstorm, .wezterm, .windsurf, .xcode, .zed, .zedPreview:
      title
    }
  }

  public var menuIcon: MenuIcon? {
    switch self {
    case .editor:
      return .symbol("apple.terminal")
    default:
      guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
      else { return nil }
      return .app(NSWorkspace.shared.icon(forFile: appURL.path))
    }
  }

  public var isInstalled: Bool {
    switch self {
    case .finder, .editor:
      return true
    case .alacritty, .androidStudio, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken,
      .gitup, .ghostty, .goland, .intellij, .intellijEAP, .kitty, .nova, .pycharm, .rider, .rubymine,
      .rustrover, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders,
      .vscodium, .warp, .webstorm, .wezterm, .windsurf, .xcode, .zed, .zedPreview:
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
  }

  public var settingsID: String {
    switch self {
    case .finder: "finder"
    case .editor: "editor"
    case .alacritty: "alacritty"
    case .androidStudio: "android-studio"
    case .antigravity: "antigravity"
    case .cursor: "cursor"
    case .fork: "fork"
    case .githubDesktop: "github-desktop"
    case .gitkraken: "gitkraken"
    case .gitup: "gitup"
    case .ghostty: "ghostty"
    case .goland: "goland"
    case .intellij: "intellij"
    case .intellijEAP: "intellijEAP"
    case .kitty: "kitty"
    case .nova: "nova"
    case .pycharm: "pycharm"
    case .rider: "rider"
    case .rubymine: "rubymine"
    case .rustrover: "rustrover"
    case .smartgit: "smartgit"
    case .sourcetree: "sourcetree"
    case .sublimeMerge: "sublime-merge"
    case .terminal: "terminal"
    case .vscode: "vscode"
    case .vscodeInsiders: "vscode-insiders"
    case .vscodium: "vscodium"
    case .warp: "warp"
    case .webstorm: "webstorm"
    case .wezterm: "wezterm"
    case .windsurf: "windsurf"
    case .xcode: "xcode"
    case .zed: "zed"
    case .zedPreview: "zed-preview"
    }
  }

  public var bundleIdentifier: String {
    switch self {
    case .finder: "com.apple.finder"
    case .editor: ""
    case .alacritty: "org.alacritty"
    case .androidStudio: "com.google.android.studio"
    case .antigravity: "com.google.antigravity"
    case .cursor: "com.todesktop.230313mzl4w4u92"
    case .fork: "com.DanPristupov.Fork"
    case .githubDesktop: "com.github.GitHubClient"
    case .gitkraken: "com.axosoft.gitkraken"
    case .gitup: "co.gitup.mac"
    case .ghostty: "com.mitchellh.ghostty"
    case .goland: "com.jetbrains.goland"
    case .intellij: "com.jetbrains.intellij"
    case .intellijEAP: "com.jetbrains.intellij-EAP"
    case .kitty: "net.kovidgoyal.kitty"
    case .nova: "com.panic.Nova"
    case .pycharm: "com.jetbrains.pycharm"
    case .rider: "com.jetbrains.rider"
    case .rubymine: "com.jetbrains.rubymine"
    case .rustrover: "com.jetbrains.rustrover"
    case .smartgit: "com.syntevo.smartgit"
    case .sourcetree: "com.torusknot.SourceTreeNotMAS"
    case .sublimeMerge: "com.sublimemerge"
    case .terminal: "com.apple.Terminal"
    case .vscode: "com.microsoft.VSCode"
    case .vscodeInsiders: "com.microsoft.VSCodeInsiders"
    case .vscodium: "com.vscodium"
    case .warp: "dev.warp.Warp-Stable"
    case .webstorm: "com.jetbrains.WebStorm"
    case .wezterm: "com.github.wez.wezterm"
    case .windsurf: "com.exafunction.windsurf"
    case .xcode: "com.apple.dt.Xcode"
    case .zed: "dev.zed.Zed"
    case .zedPreview: "dev.zed.Zed-Preview"
    }
  }

  public var openTargets: [OpenTarget] {
    switch self {
    case .xcode:
      [
        .search(#"\.xcworkspace$"#, excludeDirectories: Self.xcodeSearchExcludedDirectories),
        .search(#"\.xcodeproj$"#, excludeDirectories: Self.xcodeSearchExcludedDirectories),
        .default,
      ]
    case .alacritty, .androidStudio, .antigravity, .cursor, .editor, .finder, .fork, .githubDesktop,
      .gitkraken, .gitup, .ghostty, .goland, .intellij, .intellijEAP, .kitty, .nova, .pycharm, .rider,
      .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode,
      .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf, .zed, .zedPreview:
      [.default]
    }
  }

  public var openBehaviors: [OpenBehavior] {
    switch self {
    case .androidStudio, .goland, .intellij, .intellijEAP, .rider, .webstorm, .pycharm, .rubymine, .rustrover:
      [
        .workspace(
          configuration:
            .init(
              createsNewApplicationInstance: true,
              arguments: [.targetPath]
            )
        )
      ]
    case .zed, .zedPreview:
      [
        .process(
          .appRelativePath("Contents/MacOS/cli"),
          args: [.targetPath]
        ),
        .default,
      ]
    case .alacritty, .antigravity, .cursor, .editor, .finder, .fork, .githubDesktop, .gitkraken, .gitup,
      .ghostty, .kitty, .nova, .smartgit, .sourcetree, .sublimeMerge, .terminal, .vscode, .vscodeInsiders,
      .vscodium, .warp, .wezterm, .windsurf, .xcode:
      [.default]
    }
  }

  public nonisolated static let automaticSettingsID = "auto"

  public static let editorPriority: [OpenWorktreeAction] = [
    .cursor,
    .zed,
    .zedPreview,
    .vscode,
    .windsurf,
    .vscodeInsiders,
    .vscodium,
    .androidStudio,
    .goland,
    .intellij,
    .intellijEAP,
    .webstorm,
    .pycharm,
    .rubymine,
    .rider,
    .rustrover,
    .nova,
    .antigravity,
  ]
  public static let terminalPriority: [OpenWorktreeAction] = [
    .ghostty,
    .wezterm,
    .alacritty,
    .kitty,
    .warp,
    .terminal,
  ]
  public static let gitClientPriority: [OpenWorktreeAction] = [
    .githubDesktop,
    .sourcetree,
    .fork,
    .gitkraken,
    .sublimeMerge,
    .smartgit,
    .gitup,
  ]
  public static let defaultPriority: [OpenWorktreeAction] =
    editorPriority + [.xcode, .finder] + terminalPriority + gitClientPriority
  public static let menuOrder: [OpenWorktreeAction] =
    editorPriority + [.xcode] + [.finder] + terminalPriority + gitClientPriority + [.editor]

  public static func normalizedDefaultEditorID(_ settingsID: String?) -> String {
    guard let settingsID, settingsID != automaticSettingsID else {
      return automaticSettingsID
    }
    guard let action = allCases.first(where: { $0.settingsID == settingsID }),
      action.isInstalled
    else {
      return automaticSettingsID
    }
    return settingsID
  }

  public static func fromSettingsID(
    _ settingsID: String?,
    defaultEditorID: String?
  ) -> OpenWorktreeAction {
    if let settingsID, settingsID != automaticSettingsID,
      let action = allCases.first(where: { $0.settingsID == settingsID })
    {
      return action
    }
    let normalizedDefaultEditorID = normalizedDefaultEditorID(defaultEditorID)
    if normalizedDefaultEditorID != automaticSettingsID,
      let action = allCases.first(where: { $0.settingsID == normalizedDefaultEditorID })
    {
      return action
    }
    return preferredDefault()
  }

  public static var availableCases: [OpenWorktreeAction] {
    menuOrder.filter(\.isInstalled)
  }

  public static func availableSelection(_ selection: OpenWorktreeAction) -> OpenWorktreeAction {
    selection.isInstalled ? selection : preferredDefault()
  }

  public static func preferredDefault() -> OpenWorktreeAction {
    defaultPriority.first(where: \.isInstalled) ?? .finder
  }

  private static let xcodeSearchExcludedDirectories =
    #"(^|/)("#
    + #"\.build|\.dart_tool|\.expo|\.expo-shared|\.git|\.gradle|\.pnpm-store"#
    + #"|\.swiftpm|\.symlinks|\.yarn|Carthage|DerivedData|Pods|build|node_modules"#
    + #"|[^/]+\.xcodeproj|[^/]+\.xcworkspace"#
    + #")(/|$)"#
}
