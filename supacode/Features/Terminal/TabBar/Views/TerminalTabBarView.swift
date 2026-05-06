import SwiftUI

struct TerminalTabBarView: View {
  @Bindable var manager: TerminalTabManager
  let createTab: () -> Void
  let splitHorizontally: () -> Void
  let splitVertically: () -> Void
  let canSplit: Bool
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let renameTab: (TerminalTabID, String) -> Void
  let hasNotification: (TerminalTabID) -> Bool
  @Environment(\.controlActiveState)
  private var controlActiveState

  var body: some View {
    HStack(spacing: 0) {
      TerminalTabsView(
        manager: manager,
        closeTab: closeTab,
        closeOthers: closeOthers,
        closeToRight: closeToRight,
        closeAll: closeAll,
        renameTab: renameTab,
        hasNotification: hasNotification
      )
      Spacer(minLength: 0)
      TerminalTabBarTrailingAccessories(
        createTab: createTab,
        splitHorizontally: splitHorizontally,
        splitVertically: splitVertically,
        canSplit: canSplit
      )
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
  }
}
