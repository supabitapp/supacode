import Foundation
import Sharing
import SupacodeSettingsShared

struct CommandPaletteItem: Identifiable, Equatable {
  static let defaultPriorityTier = 100

  let id: String
  let title: String
  let subtitle: String?
  let kind: Kind
  let priorityTier: Int
  /// `true` for the worktree-switcher row that represents the worktree the
  /// user is already in. The switcher still renders it (so you can see
  /// where you are), but the overlay skips it for the default selection so
  /// ⌘P then Enter lands on the previous worktree instead of being a
  /// no-op. Always `false` outside the worktree switcher.
  let isCurrentWorktree: Bool
  /// Presentation for a worktree-switcher row: text tints, leading icon, and
  /// the remote host, mirroring the sidebar. `nil` for every non-switcher item.
  let worktreeStyle: WorktreeRowStyle?
  /// Tints the subtitle to match the target's sidebar color. Used by the
  /// customize-appearance actions so the palette echoes the sidebar tint.
  let subtitleTint: RepositoryColor?

  /// Tints, leading icon, and the remote host for a worktree-switcher row.
  /// Colors are applied to the title / subtitle text directly, matching the
  /// sidebar.
  struct WorktreeRowStyle: Equatable {
    /// Tints the title (the worktree name, or a folder row's own name).
    var titleTint: RepositoryColor?
    /// Tints the repo-name subtitle. `nil` for folder rows, which have no subtitle.
    var repoTint: RepositoryColor?
    /// SSH authority for a remote row; drives a `wifi` badge. `nil` when local.
    var hostInfo: String?
    /// Leading glyph, mirroring the sidebar row's icon. Every switcher row has one.
    var icon: WorktreeRowIcon
  }

  /// Leading glyph for a worktree-switcher row, mirroring the sidebar. The
  /// switcher lists only idle rows, so the sidebar's lifecycle variants collapse
  /// to these three outcomes.
  enum WorktreeRowIcon: Equatable {
    /// Git worktree: a template asset (`git-branch` or a pull-request variant),
    /// optionally badged with the pull request's aggregate check state.
    case pullRequest(SidebarPullRequestIcon, checkBadge: SidebarCheckBadgeState?)
    /// A folder row.
    case folder
    /// A worktree whose working directory is missing.
    case missing
  }

  init(
    id: String,
    title: String,
    subtitle: String?,
    kind: Kind,
    priorityTier: Int = defaultPriorityTier,
    isCurrentWorktree: Bool = false,
    worktreeStyle: WorktreeRowStyle? = nil,
    subtitleTint: RepositoryColor? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.kind = kind
    self.priorityTier = priorityTier
    self.isCurrentWorktree = isCurrentWorktree
    self.worktreeStyle = worktreeStyle
    self.subtitleTint = subtitleTint
  }

  enum Kind: Equatable {
    case checkForUpdates
    case openRepository
    case addRemoteRepository
    case worktreeSelect(Worktree.ID)
    case openSettings
    case newWorktree
    case removeWorktree(Worktree.ID, Repository.ID)
    case archiveWorktree(Worktree.ID, Repository.ID)
    case renameBranch(Worktree.ID, Repository.ID)
    case customizeRepositoryAppearance(Repository.ID)
    case customizeWorktreeAppearance(Worktree.ID, Repository.ID)
    case viewArchivedWorktrees
    case refreshWorktrees
    case ghosttyCommand(String)
    case toggleWindowMode
    case layoutCommand(LayoutPaletteCommand)
    case openPullRequest(Worktree.ID)
    case markPullRequestReady(Worktree.ID)
    case mergePullRequest(Worktree.ID)
    case closePullRequest(Worktree.ID)
    case copyFailingJobURL(Worktree.ID)
    case copyCiFailureLogs(Worktree.ID)
    case rerunFailedJobs(Worktree.ID)
    case openFailingCheckDetails(Worktree.ID)
    case runScript(ScriptDefinition)
    case stopScript(UUID, name: String)
    #if DEBUG
      case debugTestToast(RepositoriesFeature.StatusToast)
    #endif
  }

  var isGlobal: Bool {
    switch kind {
    case .checkForUpdates, .openRepository, .addRemoteRepository, .openSettings, .newWorktree,
      .viewArchivedWorktrees, .refreshWorktrees:
      true
    case .ghosttyCommand, .toggleWindowMode, .layoutCommand:
      false
    case .openPullRequest,
      .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails:
      true
    case .worktreeSelect, .removeWorktree, .archiveWorktree:
      false
    case .renameBranch, .customizeRepositoryAppearance, .customizeWorktreeAppearance:
      true
    case .runScript, .stopScript:
      true
    #if DEBUG
      case .debugTestToast:
        true
    #endif
    }
  }

  var isRootAction: Bool {
    switch kind {
    case .checkForUpdates, .openRepository, .addRemoteRepository, .openSettings, .newWorktree,
      .viewArchivedWorktrees, .refreshWorktrees:
      true
    case .ghosttyCommand, .toggleWindowMode, .layoutCommand:
      false
    case .openPullRequest,
      .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .worktreeSelect,
      .removeWorktree,
      .archiveWorktree,
      .renameBranch,
      .customizeRepositoryAppearance,
      .customizeWorktreeAppearance:
      false
    case .runScript, .stopScript:
      false
    #if DEBUG
      case .debugTestToast:
        false
    #endif
    }
  }

  var appShortcut: AppShortcut? {
    switch kind {
    case .checkForUpdates: AppShortcuts.checkForUpdates
    case .openRepository: AppShortcuts.openRepository
    case .openSettings: AppShortcuts.openSettings
    case .newWorktree: AppShortcuts.newWorktree
    case .viewArchivedWorktrees: AppShortcuts.archivedWorktrees
    case .refreshWorktrees: AppShortcuts.refreshWorktrees
    case .ghosttyCommand: nil
    case .toggleWindowMode: AppShortcuts.toggleWindowMode
    case .layoutCommand(let command): command.appShortcut
    case .openPullRequest: AppShortcuts.openPullRequest
    case .addRemoteRepository,
      .markPullRequestReady,
      .mergePullRequest,
      .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs,
      .openFailingCheckDetails,
      .worktreeSelect,
      .removeWorktree,
      .archiveWorktree,
      .renameBranch,
      .customizeRepositoryAppearance,
      .customizeWorktreeAppearance,
      .stopScript:
      nil
    case .runScript(let definition):
      definition.kind == .run ? AppShortcuts.runScript : nil
    #if DEBUG
      case .debugTestToast:
        nil
    #endif
    }
  }

  var appShortcutLabel: String? {
    effectiveAppShortcut?.display
  }

  var appShortcutSymbols: [String]? {
    effectiveAppShortcut?.displaySymbols
  }

  private var effectiveAppShortcut: AppShortcut? {
    guard let shortcut = appShortcut else { return nil }
    @Shared(.settingsFile) var settingsFile
    return shortcut.effective(from: settingsFile.global.shortcutOverrides)
  }
}

/// The app-owned layout commands the palette offers in place of Ghostty's
/// topology entries.
enum LayoutPaletteCommand: String, CaseIterable, Equatable, Sendable {
  case newTerminalTab = "new-terminal-tab"
  case closeTab = "close-tab"
  case splitRight = "split-right"
  case splitLeft = "split-left"
  case splitDown = "split-down"
  case splitUp = "split-up"
  case focusSplitRight = "focus-split-right"
  case focusSplitLeft = "focus-split-left"
  case focusSplitDown = "focus-split-down"
  case focusSplitUp = "focus-split-up"
  case toggleSplitZoom = "toggle-split-zoom"
  case equalizeSplits = "equalize-splits"

  var title: String {
    switch self {
    case .newTerminalTab: "New Terminal Tab"
    case .closeTab: "Close Tab"
    case .splitRight: "Split Right"
    case .splitLeft: "Split Left"
    case .splitDown: "Split Down"
    case .splitUp: "Split Up"
    case .focusSplitRight: "Focus Split Right"
    case .focusSplitLeft: "Focus Split Left"
    case .focusSplitDown: "Focus Split Down"
    case .focusSplitUp: "Focus Split Up"
    case .toggleSplitZoom: "Toggle Split Zoom"
    case .equalizeSplits: "Equalize Splits"
    }
  }

  /// SF Symbol for the palette row.
  var systemImage: String {
    switch self {
    case .newTerminalTab: "macwindow"
    case .closeTab: "xmark"
    case .splitRight: TerminalSplitMenuDirection.right.systemImage
    case .splitLeft: TerminalSplitMenuDirection.left.systemImage
    case .splitDown: TerminalSplitMenuDirection.down.systemImage
    case .splitUp: TerminalSplitMenuDirection.up.systemImage
    case .focusSplitRight: "arrow.right"
    case .focusSplitLeft: "arrow.left"
    case .focusSplitDown: "arrow.down"
    case .focusSplitUp: "arrow.up"
    case .toggleSplitZoom: "arrow.up.left.and.arrow.down.right"
    case .equalizeSplits: "rectangle.split.2x1"
    }
  }

  /// The app shortcut shown next to the palette entry, when one exists.
  var appShortcut: AppShortcut? {
    switch self {
    case .newTerminalTab: AppShortcuts.newTerminalTab
    case .closeTab: AppShortcuts.closeTab
    case .splitRight: AppShortcuts.splitRight
    case .splitLeft: AppShortcuts.splitLeft
    case .splitDown: AppShortcuts.splitDown
    case .splitUp: AppShortcuts.splitUp
    case .focusSplitRight: AppShortcuts.focusSplitRight
    case .focusSplitLeft: AppShortcuts.focusSplitLeft
    case .focusSplitDown: AppShortcuts.focusSplitDown
    case .focusSplitUp: AppShortcuts.focusSplitUp
    case .toggleSplitZoom: AppShortcuts.toggleSplitZoom
    case .equalizeSplits: AppShortcuts.equalizeSplits
    }
  }
}
