import SwiftUI

struct TerminalTabBarTrailingAccessories: View {
  let createTab: () -> Void
  let split: (TerminalSplitMenuDirection) -> Void
  let canSplit: Bool

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentTrailingSpacing) {
      TerminalTabBarAccessoryButton(
        title: "New Tab",
        systemImage: "plus",
        shortcutBinding: "new_tab",
        action: createTab
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
  let shortcutBinding: String
  let action: () -> Void

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts

  var body: some View {
    let shortcut = ghosttyShortcuts.display(for: shortcutBinding)

    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.iconOnly)
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
