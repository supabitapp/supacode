import ComposableArchitecture
import SwiftUI

struct MobileContentView: View {
  @Bindable var store: StoreOf<MobileAppFeature>
  let terminalManager: MobileTerminalSessionManager

  @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $sidebarVisibility) {
      MobileSidebarView(
        store: store,
        terminalManager: terminalManager,
      )
      .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
      .navigationTitle("Supacode")
    } detail: {
      if store.selectedServerID != nil {
        MobileDetailView(
          store: store,
          terminalManager: terminalManager,
        )
      } else {
        MobileEmptyStateView {
          store.send(.addServerTapped)
        }
      }
    }
    .sheet(item: $store.scope(state: \.serverForm, action: \.serverForm)) { formStore in
      MobileServerFormView(store: formStore)
    }
  }
}
