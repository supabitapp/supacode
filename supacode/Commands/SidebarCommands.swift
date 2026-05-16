import Sharing
import SupacodeSettingsShared
import SwiftUI

struct SidebarCommands: Commands {
  @FocusedValue(\.toggleLeftSidebarAction) private var toggleLeftSidebarAction
  @FocusedValue(\.revealInSidebarAction) private var revealInSidebarAction
  @Shared(.settingsFile) private var settingsFile
  @Shared(.appStorage("worktreeRowDisplayMode")) private var displayMode: WorktreeRowDisplayMode = .branchFirst
  @Shared(.appStorage("worktreeRowHideSubtitleOnMatch")) private var hideSubtitleOnMatch = true
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool
  @Shared(.appStorage("nestedWorktreesOnboardingDismissedAt"))
  private var nestedOnboardingDismissedAt: Date = .distantPast

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
        Picker("Title and Subtitle", systemImage: "textformat", selection: Binding($displayMode)) {
          ForEach(WorktreeRowDisplayMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        Toggle("Hide Subtitle on Match", isOn: Binding($hideSubtitleOnMatch))
        Toggle("Nest Worktrees by Branch", isOn: nestWorktreesToggle)
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
