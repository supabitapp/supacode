import Foundation

public nonisolated enum OpenTarget: Equatable, Sendable {
  case workingDirectory
  case url(URL)
  case search(String, excludeDirectories: String? = nil, maxDepth: Int = 3)

  public static let `default`: Self = .workingDirectory
}

public nonisolated enum OpenBehavior: Equatable, Sendable {
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

/// How to open a remote SSH worktree through an editor's Remote-SSH CLI.
public nonisolated struct RemoteOpenInvocation: Equatable, Sendable {
  public var executable: OpenBehavior.ProcessExecutable
  /// argv following the resolved executable (and its prefix).
  public var arguments: [String]

  public init(executable: OpenBehavior.ProcessExecutable, arguments: [String]) {
    self.executable = executable
    self.arguments = arguments
  }
}

/// A pure value: it never touches `NSWorkspace`. Availability and icons are
/// resolved off the menu-build path (`OpenActionAvailabilityClient`).
public nonisolated enum OpenWorktreeAction: CaseIterable, Identifiable, Hashable, Sendable {
  case alacritty
  case androidStudio
  case antigravity
  case editor
  case finder
  case cursor
  case trae
  case traeCN
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
  case phpstorm
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
    case .trae: "Trae"
    case .traeCN: "Trae CN"
    case .githubDesktop: "GitHub Desktop"
    case .gitkraken: "GitKraken"
    case .gitup: "GitUp"
    case .ghostty: "Ghostty"
    case .goland: "GoLand"
    case .intellij: "IntelliJ IDEA"
    case .intellijEAP: "IntelliJ IDEA EAP"
    case .kitty: "Kitty"
    case .nova: "Nova"
    case .phpstorm: "PhpStorm"
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
      .gitup, .ghostty, .goland, .intellij, .intellijEAP, .kitty, .nova, .phpstorm, .pycharm,
      .rider, .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge, .terminal, .trae,
      .traeCN, .vscode, .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf, .xcode,
      .zed, .zedPreview:
      title
    }
  }

  /// The SF Symbol standing in for this action, or `nil` when it renders the
  /// app's own icon. Only `$EDITOR` has no bundle to draw from.
  public var menuSymbolName: String? {
    self == .editor ? "apple.terminal" : nil
  }

  /// Whether availability depends on an installed app bundle. Finder always
  /// exists and `$EDITOR` resolves through the shell, so both are unconditional.
  public var requiresInstalledApplication: Bool {
    switch self {
    case .finder, .editor: false
    default: true
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
    case .trae: "trae"
    case .traeCN: "trae-cn"
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
    case .phpstorm: "phpstorm"
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
    case .trae: "com.trae.app"
    case .traeCN: "cn.trae.app"
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
    case .phpstorm: "com.jetbrains.PhpStorm"
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
      .gitkraken, .gitup, .ghostty, .goland, .intellij, .intellijEAP, .kitty, .nova, .phpstorm,
      .pycharm, .rider, .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge, .terminal,
      .trae, .traeCN, .vscode, .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf,
      .zed, .zedPreview:
      [.default]
    }
  }

  public var openBehaviors: [OpenBehavior] {
    switch self {
    case .androidStudio, .goland, .intellij, .intellijEAP, .phpstorm, .rider, .webstorm, .pycharm,
      .rubymine, .rustrover:
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
      .ghostty, .kitty, .nova, .smartgit, .sourcetree, .sublimeMerge, .terminal, .trae, .traeCN,
      .vscode, .vscodeInsiders, .vscodium, .warp, .wezterm, .windsurf, .xcode:
      [.default]
    }
  }

  /// How to open this worktree on `host` at `remotePath` via the editor's
  /// Remote-SSH CLI, or `nil` if the editor can't express this host. The single
  /// capability signal shared by the reducer guard and the UI enablement.
  public func remoteOpenInvocation(host: RemoteHost, remotePath: String) -> RemoteOpenInvocation? {
    switch self {
    case .zed, .zedPreview:
      return RemoteOpenInvocation(
        executable: .appRelativePath("Contents/MacOS/cli"),
        arguments: [Self.zedSSHURL(host: host, remotePath: remotePath)]
      )
    case .vscode, .vscodeInsiders, .vscodium, .cursor, .trae, .traeCN, .windsurf, .antigravity:
      // VS Code parses `ssh-remote+host:2222` as a literal hostname, so it has no
      // inline port syntax (microsoft/vscode-remote-release #515): a non-default
      // port is inexpressible, so return `nil`. The path is a literal positional
      // argv (no shell, no URL), so it is NOT percent-encoded.
      guard !host.hasNonDefaultPort else { return nil }
      guard let cliName = vscodeFamilyCLIName else { return nil }
      return RemoteOpenInvocation(
        executable: .appRelativePath("Contents/Resources/app/bin/\(cliName)"),
        arguments: ["--remote", "ssh-remote+\(host.sshDestination)", remotePath]
      )
    default:
      return nil
    }
  }

  /// The bundled CLI binary name (under `Contents/Resources/app/bin/`) for the
  /// VS Code family, or `nil` for any other editor. Doubles as the family
  /// membership test backing the disabled-reason tooltip.
  private var vscodeFamilyCLIName: String? {
    switch self {
    case .vscode: "code"
    case .vscodeInsiders: "code-insiders"
    case .vscodium: "codium"
    case .cursor: "cursor"
    case .trae: "trae"
    case .traeCN: "trae-cn"
    case .windsurf: "windsurf"
    case .antigravity: "antigravity"
    default: nil
    }
  }

  /// A human-facing reason this editor is disabled for `host` at `remotePath`, or
  /// `nil` when it can open, so a reason structurally implies a disabled item.
  /// Non-`nil` only for the VS Code family on a non-default port. Presentation
  /// only; gating stays on `remoteOpenInvocation`.
  public func remoteOpenDisabledReason(host: RemoteHost, remotePath: String) -> String? {
    guard remoteOpenInvocation(host: host, remotePath: remotePath) == nil, vscodeFamilyCLIName != nil else {
      return nil
    }
    return "Opening \(title) over SSH needs the port in ~/.ssh/config"
  }

  /// `ssh://[user@]host[:port]<remotePath>` for Zed's Remote-SSH CLI. The path
  /// is normalized to a leading `/` so it can't fuse with the authority into a
  /// malformed `ssh://host~/proj`, then percent-encoded for URI validity (e.g.
  /// spaces); `.urlPathAllowed` keeps the `/` separators intact.
  private static func zedSSHURL(host: RemoteHost, remotePath: String) -> String {
    let normalizedPath = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
    let encodedPath =
      normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedPath
    return "ssh://\(host.sshURLAuthority)\(encodedPath)"
  }

  public static let automaticSettingsID = "auto"

  public static let editorPriority: [OpenWorktreeAction] = [
    .cursor,
    .trae,
    .traeCN,
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
    .phpstorm,
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

  public static func normalizedDefaultEditorID(
    _ settingsID: String?,
    installed: [OpenWorktreeAction]
  ) -> String {
    guard let settingsID, settingsID != automaticSettingsID else {
      return automaticSettingsID
    }
    guard let action = allCases.first(where: { $0.settingsID == settingsID }),
      installed.contains(action)
    else {
      return automaticSettingsID
    }
    return settingsID
  }

  /// What to present for a repository the resolution pass has not reached yet: a cold
  /// launch, or one just added. Resolving the same chain minus the repository's own
  /// `supacode.json` keeps the value from jumping when the pass lands, which skipping
  /// to `preferredDefault` would not: it ignores the user's default editor.
  public static func unresolvedDefault(
    defaultEditorID: String?,
    installed: [OpenWorktreeAction]
  ) -> OpenWorktreeAction {
    fromSettingsID(nil, defaultEditorID: defaultEditorID, installed: installed)
  }

  public static func fromSettingsID(
    _ settingsID: String?,
    defaultEditorID: String?,
    installed: [OpenWorktreeAction]
  ) -> OpenWorktreeAction {
    if let settingsID, settingsID != automaticSettingsID,
      let action = allCases.first(where: { $0.settingsID == settingsID })
    {
      return action
    }
    let normalizedDefaultEditorID = normalizedDefaultEditorID(defaultEditorID, installed: installed)
    if normalizedDefaultEditorID != automaticSettingsID,
      let action = allCases.first(where: { $0.settingsID == normalizedDefaultEditorID })
    {
      return action
    }
    return preferredDefault(installed: installed)
  }

  public static func availableSelection(
    _ selection: OpenWorktreeAction,
    installed: [OpenWorktreeAction]
  ) -> OpenWorktreeAction {
    installed.contains(selection) ? selection : preferredDefault(installed: installed)
  }

  public static func preferredDefault(installed: [OpenWorktreeAction]) -> OpenWorktreeAction {
    defaultPriority.first { installed.contains($0) } ?? .finder
  }

  private static let xcodeSearchExcludedDirectories =
    #"(^|/)("#
    + #"\.build|\.dart_tool|\.expo|\.expo-shared|\.git|\.gradle|\.pnpm-store"#
    + #"|\.swiftpm|\.symlinks|\.yarn|Carthage|DerivedData|Pods|build|node_modules"#
    + #"|[^/]+\.xcodeproj|[^/]+\.xcworkspace"#
    + #")(/|$)"#
}
