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

  /// Group Pinned Rows toggle. When the user turns it off and the Active
  /// toggle is already off, the highlight onboarding card has nothing left
  /// to advertise — permadismiss it so it doesn't reappear on next launch.
  private var groupPinnedRowsToggle: Binding<Bool> {
    Binding(
      get: { groupPinnedRows },
      set: { newValue in
        $groupPinnedRows.withLock { $0 = newValue }
        autoDismissHighlightOnboardingIfFullyDisabled(
          afterPinned: newValue,
          afterActive: groupActiveRows
        )
      }
    )
  }

  private var groupActiveRowsToggle: Binding<Bool> {
    Binding(
      get: { groupActiveRows },
      set: { newValue in
        $groupActiveRows.withLock { $0 = newValue }
        autoDismissHighlightOnboardingIfFullyDisabled(
          afterPinned: groupPinnedRows,
          afterActive: newValue
        )
      }
    )
  }

  private func autoDismissHighlightOnboardingIfFullyDisabled(
    afterPinned: Bool,
    afterActive: Bool
  ) {
    guard !afterPinned, !afterActive,
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
      .disabled(toggleLeftSidebarAction == nil)
      Button("Reveal in Sidebar") {
        revealInSidebarAction?()
      }
      .appKeyboardShortcut(revealInSidebar)
      .help("Reveal in Sidebar (\(revealInSidebar?.display ?? "none"))")
      .disabled(revealInSidebarAction == nil)
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
  typealias Value = () -> Void
}

private struct RevealInSidebarActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var toggleLeftSidebarAction: (() -> Void)? {
    get { self[ToggleLeftSidebarActionKey.self] }
    set { self[ToggleLeftSidebarActionKey.self] = newValue }
  }

  var revealInSidebarAction: (() -> Void)? {
    get { self[RevealInSidebarActionKey.self] }
    set { self[RevealInSidebarActionKey.self] = newValue }
  }
}
