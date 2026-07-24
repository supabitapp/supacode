import Sharing
import SupacodeSettingsShared
import SwiftUI

struct TerminalTabBarTrailingAccessories: View {
  let createTab: () -> Void
  let createScratchpad: () -> Void
  let split: (TerminalSplitMenuDirection) -> Void
  let canSplit: Bool
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentTrailingSpacing) {
      TerminalTabBarAccessoryButton(
        title: "New Tab",
        systemImage: "plus",
        shortcutBinding: "new_tab",
        action: createTab
      )
      TerminalTabBarAccessoryButton(
        title: "New Scratchpad",
        systemImage: "note.text",
        staticShortcutDisplay: AppShortcuts.newScratchpad
          .effective(from: settingsFile.global.shortcutOverrides)?.display,
        action: createScratchpad
      )
      TerminalTabBarSplitMenu(primary: .right, secondary: .left, split: split)
        .disabled(!canSplit)
      TerminalTabBarSplitMenu(primary: .down, secondary: .up, split: split)
        .disabled(!canSplit)
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .padding(.trailing, 8)
  }
}

private struct TerminalTabBarAccessoryButton: View {
  let title: String
  let systemImage: String
  /// Ghostty binding whose user-resolved shortcut the tooltip shows.
  var shortcutBinding: String?
  /// Fixed display for app-level (non-Ghostty) shortcuts like the scratchpad's.
  var staticShortcutDisplay: String?
  let action: () -> Void

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts

  var body: some View {
    let shortcut = shortcutBinding.flatMap(ghosttyShortcuts.display(for:)) ?? staticShortcutDisplay

    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
        .frame(minWidth: TerminalTabBarMetrics.barHeight, minHeight: TerminalTabBarMetrics.barHeight)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(helpText(shortcut: shortcut))
  }

  private func helpText(shortcut: String?) -> String {
    guard let shortcut else { return title }
    return "\(title) (\(shortcut))"
  }
}

private struct TerminalTabBarSplitMenu: View {
  let primary: TerminalSplitMenuDirection
  let secondary: TerminalSplitMenuDirection
  let split: (TerminalSplitMenuDirection) -> Void

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts

  var body: some View {
    let primaryShortcut = ghosttyShortcuts.display(for: primary.ghosttyBinding)

    Menu {
      Button(primary.title, systemImage: primary.systemImage) {
        split(primary)
      }
      .ghosttyKeyboardShortcut(primary.ghosttyBinding, in: ghosttyShortcuts)
      Button(secondary.title, systemImage: secondary.systemImage) {
        split(secondary)
      }
      .ghosttyKeyboardShortcut(secondary.ghosttyBinding, in: ghosttyShortcuts)
    } label: {
      Label(primary.title, systemImage: primary.systemImage)
        .labelStyle(.iconOnly)
        .frame(minWidth: TerminalTabBarMetrics.barHeight, minHeight: TerminalTabBarMetrics.barHeight)
        .contentShape(.rect)
    } primaryAction: {
      split(primary)
    }
    .menuStyle(.secondaryToolbar)
    .help(helpText(shortcut: primaryShortcut))
  }

  private func helpText(shortcut: String?) -> String {
    guard let shortcut else { return primary.title }
    return "\(primary.title) (\(shortcut))"
  }
}
