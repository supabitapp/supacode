import SupacodeSettingsShared
import SwiftUI

struct TerminalTabLabelView: View {
  let tab: TerminalTabItem
  let isActive: Bool
  let isHoveringTab: Bool
  let isHoveringClose: Bool
  let hasNotification: Bool
  let shortcutHint: String?
  let showsShortcutHint: Bool

  var body: some View {
    HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
      if let icon = tab.icon {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(
            tab.tintColor?.color ?? (isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
          )
          .frame(
            width: TerminalTabBarMetrics.closeButtonSize,
            height: TerminalTabBarMetrics.closeButtonSize
          )
          .accessibilityHidden(true)
      }
      if hasNotification {
        Circle()
          .fill(.orange)
          .frame(width: 6, height: 6)
          .transition(.opacity.combined(with: .scale))
          .accessibilityLabel("Unread notifications")
      }
      Text(tab.title)
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(isActive ? TerminalTabBarColors.activeText : TerminalTabBarColors.inactiveText)
        .shimmer(isActive: tab.isDirty)
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
