import ComposableArchitecture
import SwiftUI

struct MobileSidebarView: View {
  @Bindable var store: StoreOf<MobileAppFeature>
  let terminalManager: MobileTerminalSessionManager

  var body: some View {
    List(selection: $store.selectedSessionID.sending(\.selectSession)) {
      if store.sessions.isEmpty {
        Text("No open sessions")
          .foregroundStyle(.secondary)
          .font(.callout)
      } else {
        Section("Sessions") {
          ForEach(store.sessions) { session in
            let server = store.servers.servers[id: session.serverID]
            MobileSessionRow(
              serverName: server?.displayName ?? "Unknown",
              sessionTitle: session.title,
              isClosed: session.isClosed,
            )
            .tag(session.id)
            .contextMenu {
              Button("Close Session", systemImage: "xmark", role: .destructive) {
                store.send(.closeSession(session.id))
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      MobileSidebarFooterView {
        store.send(.connectButtonTapped)
      }
    }
  }
}
