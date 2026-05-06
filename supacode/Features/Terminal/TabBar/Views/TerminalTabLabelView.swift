import SupacodeSettingsShared
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
      if let icon = tab.icon {
        Image(systemName: icon)
          .imageScale(.small)
          .foregroundStyle(tab.tintColor?.color ?? TerminalTabBarColors.activeText)
          .frame(
            width: TerminalTabBarMetrics.closeButtonSize,
            height: TerminalTabBarMetrics.closeButtonSize
          )
          .accessibilityHidden(true)
      }
      Text(tab.displayTitle)
        .font(.caption)
        .fontWeight(isActive ? .semibold : .regular)
        .lineLimit(1)
        .foregroundStyle(TerminalTabBarColors.activeText)
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
