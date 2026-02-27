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
      if store.selectedSessionID != nil {
        MobileDetailView(
          store: store,
          terminalManager: terminalManager,
        )
      } else {
        MobileEmptyStateView {
          store.send(.connectButtonTapped)
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: { store.showServerList },
        set: { newValue in
          if !newValue {
            store.send(.serverListDismissed)
          }
        }
      )
    ) {
      MobileServerListView(store: store)
    }
    .sheet(item: $store.scope(state: \.serverForm, action: \.serverForm)) { formStore in
      MobileServerFormView(store: formStore)
    }
  }
}
