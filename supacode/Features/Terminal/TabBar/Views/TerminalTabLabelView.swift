import SwiftUI

struct TerminalTabLabelView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isHoveringTab: Bool
  let isHoveringClose: Bool
  let shortcutHint: String?
  let showsShortcutHint: Bool

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      if tab.isDirty || tab.icon != nil {
        ZStack {
          if tab.isDirty {
            ProgressView()
              .controlSize(.small)
              .tint(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
          } else if let icon = tab.icon {
            Image(systemName: icon)
              .imageScale(.small)
              .foregroundStyle(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
          }
        }
        .frame(
          width: TerminalTabBarMetrics.closeButtonSize,
          height: TerminalTabBarMetrics.closeButtonSize
        )
        .accessibilityHidden(true)
      }
      Text(tab.title)
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
      Spacer(minLength: TerminalTabBarMetrics.contentTrailingSpacing)
      ZStack {
        if showsShortcutHint, let shortcutHint {
          ShortcutHintView(text: shortcutHint, color: TerminalTabBarColors.inactiveText)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(.rect)
    .padding(.horizontal, TerminalTabBarMetrics.tabHorizontalPadding)
    .padding(.trailing, TerminalTabBarMetrics.closeButtonSize + TerminalTabBarMetrics.contentSpacing)
  }
}
