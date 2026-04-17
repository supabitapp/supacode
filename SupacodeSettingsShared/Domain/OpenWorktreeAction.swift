import AppKit

public enum OpenWorktreeAction: CaseIterable, Identifiable {
  public enum MenuIcon {
    case app(NSImage)
    case symbol(String)
  }

  case alacritty
  case antigravity
  case editor
  case finder
  case cursor
  case githubDesktop
  case fork
  case gitkraken
  case gitup
  case ghostty
  case intellij
  case kitty
  case pycharm
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

  public var id: String { title }

  public var title: String {
    switch self {
    case .finder: "Reveal in Finder"
    case .editor: "$EDITOR"
    case .alacritty: "Alacritty"
    case .antigravity: "Antigravity"
    case .cursor: "Cursor"
    case .githubDesktop: "GitHub Desktop"
    case .gitkraken: "GitKraken"
    case .gitup: "GitUp"
    case .ghostty: "Ghostty"
    case .intellij: "IntelliJ IDEA"
    case .kitty: "Kitty"
    case .pycharm: "PyCharm"
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
    }
  }

  public var labelTitle: String {
    switch self {
    case .finder: "Finder"
    case .editor: "$EDITOR"
    case .alacritty, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken, .gitup, .ghostty,
      .intellij, .kitty, .pycharm, .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge,
      .terminal, .vscode, .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf,
      .xcode, .zed:
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
    case .alacritty, .antigravity, .cursor, .fork, .githubDesktop, .gitkraken, .gitup, .ghostty,
      .intellij, .kitty, .pycharm, .rubymine, .rustrover, .smartgit, .sourcetree, .sublimeMerge,
      .terminal, .vscode, .vscodeInsiders, .vscodium, .warp, .webstorm, .wezterm, .windsurf,
      .xcode, .zed:
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
  }

  public var settingsID: String {
    switch self {
    case .finder: "finder"
    case .editor: "editor"
    case .alacritty: "alacritty"
    case .antigravity: "antigravity"
    case .cursor: "cursor"
    case .fork: "fork"
    case .githubDesktop: "github-desktop"
    case .gitkraken: "gitkraken"
    case .gitup: "gitup"
    case .ghostty: "ghostty"
    case .intellij: "intellij"
    case .kitty: "kitty"
    case .pycharm: "pycharm"
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
    }
  }

  public var bundleIdentifier: String {
    switch self {
    case .finder: "com.apple.finder"
    case .editor: ""
    case .alacritty: "org.alacritty"
    case .antigravity: "com.google.antigravity"
    case .cursor: "com.todesktop.230313mzl4w4u92"
    case .fork: "com.DanPristupov.Fork"
    case .githubDesktop: "com.github.GitHubClient"
    case .gitkraken: "com.axosoft.gitkraken"
    case .gitup: "co.gitup.mac"
    case .ghostty: "com.mitchellh.ghostty"
    case .intellij: "com.jetbrains.intellij"
    case .kitty: "net.kovidgoyal.kitty"
    case .pycharm: "com.jetbrains.pycharm"
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
    }
  }

  public nonisolated static let automaticSettingsID = "auto"

  public static let editorPriority: [OpenWorktreeAction] = [
    .cursor,
    .zed,
    .vscode,
    .windsurf,
    .vscodeInsiders,
    .vscodium,
    .intellij,
    .webstorm,
    .pycharm,
    .rubymine,
    .rustrover,
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
}
