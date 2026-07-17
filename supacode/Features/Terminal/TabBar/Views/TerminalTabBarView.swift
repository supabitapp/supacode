import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct TerminalTabBarView: View {
  @Bindable var manager: TerminalTabManager
  let terminalState: WorktreeTerminalState
  let terminalsStore: StoreOf<TerminalsFeature>
  let isLifecycleBusy: Bool
  let createTab: () -> Void
  let split: (TerminalSplitMenuDirection) -> Void
  let canSplit: Bool
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let dismissSplitZoom: (TerminalTabID) -> Void
  let renameTab: (TerminalTabID, String) -> Void
  @Environment(\.controlActiveState)
  private var controlActiveState

  var body: some View {
    HStack(spacing: 0) {
      TerminalTabsView(
        manager: manager,
        terminalState: terminalState,
        terminalsStore: terminalsStore,
        isLifecycleBusy: isLifecycleBusy,
        closeTab: closeTab,
        closeOthers: closeOthers,
        closeToRight: closeToRight,
        closeAll: closeAll,
        dismissSplitZoom: dismissSplitZoom,
        renameTab: renameTab,
      )
      Spacer(minLength: 0)
      TerminalTabBarTrailingAccessories(
        createTab: createTab,
        split: split,
        canSplit: canSplit
      )
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .saturation(controlActiveState == .inactive ? 0 : 1)
    .clipped()
  }
}
