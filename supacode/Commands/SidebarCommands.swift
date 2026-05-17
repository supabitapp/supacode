import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarCommands: Commands {
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.revealInSidebarAction) private var revealInSidebarAction
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

extension FocusedValues {
  var toggleLeftSidebarAction: FocusedAction<Void>? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  var revealInSidebarAction: FocusedAction<Void>? {
    get { self[RevealInSidebarActionKey.self] }
    set { self[RevealInSidebarActionKey.self] = newValue }
  }
}
