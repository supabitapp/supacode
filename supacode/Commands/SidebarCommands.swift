import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarCommands: Commands {
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.revealInSidebarAction) private var revealInSidebarAction
  @FocusedValue(\.expandAllSidebarGroupsAction) private var expandAllSidebarGroupsAction
  @FocusedValue(\.collapseAllSidebarGroupsAction) private var collapseAllSidebarGroupsAction
  @FocusedValue(\.toggleInspectorPaneAction) private var toggleInspectorPaneAction
  @Shared(.settingsFile) private var settingsFile
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool
  @Shared(.appStorage("nestedWorktreesOnboardingDismissedAt"))
  private var nestedOnboardingDismissedAt: Date = .distantPast
  @Shared(.sidebarGroupPinnedRows) private var groupPinnedRows: Bool
  @Shared(.sidebarGroupActiveRows) private var groupActiveRows: Bool
  @Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))
  private var highlightOnboardingDismissedAt: Date = .distantPast

  /// Binding that pairs the nesting toggle with a permadismiss of the
  /// onboarding card on transitions to `false`. Lives on the menu command
  /// (which is always present in the menu bar) so the dismiss fires even
  /// when the sidebar column is hidden. Moving it onto the card view's
  /// `.onChange` would silently break for users who toggle while the
  /// sidebar is collapsed.
  private var nestWorktreesToggle: Binding<Bool> {
    Binding(
      get: { nestWorktreesByBranch },
      set: { newValue in
        $nestWorktreesByBranch.withLock { $0 = newValue }
        guard !newValue,
          !NestedWorktreesOnboardingCardView.isDismissed(at: nestedOnboardingDismissedAt)
        else { return }
        $nestedOnboardingDismissedAt.withLock { $0 = .now }
      }
    )
  }

  /// Mirrors `nestWorktreesToggle` so the dismiss also fires when the menu
  /// is used while the sidebar column is hidden (no `SidebarListView` body
  /// is alive to dispatch `.sidebarGroupingTogglesChanged`). The reducer
  /// handler still fires when the sidebar is visible, so this is a
  /// belt-and-suspenders pair, not the only trigger.
  private var groupPinnedRowsToggle: Binding<Bool> {
    Binding(
      get: { groupPinnedRows },
      set: { newValue in
        $groupPinnedRows.withLock { $0 = newValue }
        dismissHighlightOnboardingIfBothOff()
      }
    )
  }

  private var groupActiveRowsToggle: Binding<Bool> {
    Binding(
      get: { groupActiveRows },
      set: { newValue in
        $groupActiveRows.withLock { $0 = newValue }
        dismissHighlightOnboardingIfBothOff()
      }
    )
  }

  private func dismissHighlightOnboardingIfBothOff() {
    guard !groupPinnedRows, !groupActiveRows,
      !HighlightRelevantOnboardingCardView.isDismissed(at: highlightOnboardingDismissedAt)
    else { return }
    $highlightOnboardingDismissedAt.withLock { $0 = .now }
  }

  var body: some Commands {
    let overrides = settingsFile.global.shortcutOverrides
    let toggleLeftSidebar = AppShortcuts.toggleLeftSidebar.effective(from: overrides)
    let revealInSidebar = AppShortcuts.revealInSidebar.effective(from: overrides)
    let expandAll = AppShortcuts.expandAllSidebarGroups.effective(from: overrides)
    let collapseAll = AppShortcuts.collapseAllSidebarGroups.effective(from: overrides)
    let togglePullRequestInspector = AppShortcuts.togglePullRequestInspector.effective(from: overrides)
    let toggleNotificationsInspector = AppShortcuts.toggleNotificationsInspector.effective(from: overrides)
    CommandGroup(replacing: .sidebar) {
      Button("Toggle Left Sidebar", systemImage: "sidebar.leading") {
        toggleLeftSidebarAction?()
      }
      .appKeyboardShortcut(toggleLeftSidebar)
      .help("Toggle Left Sidebar (\(toggleLeftSidebar?.display ?? "none"))")
      .disabled(toggleLeftSidebarAction?.isEnabled != true)
      Button("Reveal in Sidebar") {
        revealInSidebarAction?()
      }
      .appKeyboardShortcut(revealInSidebar)
      .help("Reveal in Sidebar (\(revealInSidebar?.display ?? "none"))")
      .disabled(revealInSidebarAction?.isEnabled != true)
      Section {
        Button("Expand All", systemImage: "chevron.down") {
          expandAllSidebarGroupsAction?()
        }
        .appKeyboardShortcut(expandAll)
        .help("Expand all sidebar groups (\(expandAll?.display ?? "none"))")
        .disabled(expandAllSidebarGroupsAction?.isEnabled != true)
        Button("Collapse All", systemImage: "chevron.right") {
          collapseAllSidebarGroupsAction?()
        }
        .appKeyboardShortcut(collapseAll)
        .help("Collapse all sidebar groups (\(collapseAll?.display ?? "none"))")
        .disabled(collapseAllSidebarGroupsAction?.isEnabled != true)
      }
      Section {
        Button("Toggle Pull Request Inspector", systemImage: "arrow.trianglehead.branch") {
          toggleInspectorPaneAction?(.git)
        }
        .appKeyboardShortcut(togglePullRequestInspector)
        .help("Toggle Pull Request Inspector (\(togglePullRequestInspector?.display ?? "none"))")
        .disabled(toggleInspectorPaneAction?.isEnabled != true)
        Button("Toggle Notifications Inspector", systemImage: "bell") {
          toggleInspectorPaneAction?(.notifications)
        }
        .appKeyboardShortcut(toggleNotificationsInspector)
        .help("Toggle Notifications Inspector (\(toggleNotificationsInspector?.display ?? "none"))")
        .disabled(toggleInspectorPaneAction?.isEnabled != true)
      }
      Section {
        Menu("Group Relevant Sidebar Rows") {
          Toggle("Group Pinned Rows", isOn: groupPinnedRowsToggle)
          Toggle("Group Active Rows", isOn: groupActiveRowsToggle)
        }
        Toggle("Nest Worktrees by Branch", isOn: nestWorktreesToggle)
        Toggle("Hide Worktree Name on Match", isOn: Binding($hideSubtitleOnMatch))
      }
    }
  }
}

private struct ToggleLeftSidebarActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct RevealInSidebarActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct ExpandAllSidebarGroupsActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct CollapseAllSidebarGroupsActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct ToggleInspectorPaneActionKey: FocusedValueKey {
  typealias Value = FocusedAction<WorktreeInspectorPane>
}

extension FocusedValues {
  var toggleLeftSidebarAction: FocusedAction<Void>? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  var revealInSidebarAction: FocusedAction<Void>? {
    get { self[RevealInSidebarActionKey.self] }
    set { self[RevealInSidebarActionKey.self] = newValue }
  }

  var expandAllSidebarGroupsAction: FocusedAction<Void>? {
    get { self[ExpandAllSidebarGroupsActionKey.self] }
    set { self[ExpandAllSidebarGroupsActionKey.self] = newValue }
  }

  var collapseAllSidebarGroupsAction: FocusedAction<Void>? {
    get { self[CollapseAllSidebarGroupsActionKey.self] }
    set { self[CollapseAllSidebarGroupsActionKey.self] = newValue }
  }

  var toggleInspectorPaneAction: FocusedAction<WorktreeInspectorPane>? {
    get { self[ToggleInspectorPaneActionKey.self] }
    set { self[ToggleInspectorPaneActionKey.self] = newValue }
  }
}
