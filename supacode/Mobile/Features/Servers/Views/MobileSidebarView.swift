import ComposableArchitecture
import SwiftUI

struct MobileSidebarView: View {
  @Bindable var store: StoreOf<MobileAppFeature>
  let terminalManager: MobileTerminalSessionManager

  var body: some View {
    List(selection: $store.selectedServerID.sending(\.selectServer)) {
      Section("Servers") {
        ForEach(store.servers.servers) { server in
          MobileServerRow(
            server: server,
            activeSessionCount: store.sessions.filter { $0.serverID == server.id }.count,
          )
          .tag(server.id)
          .contextMenu {
            Button("Edit", systemImage: "pencil") {
              store.send(.editServerTapped(server))
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
              store.send(.servers(.delete(server.id)))
            }
          }
        }
      }

      if store.servers.servers.isEmpty {
        Text("No servers configured")
          .foregroundStyle(.secondary)
          .font(.callout)
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) {
      MobileSidebarFooterView {
        store.send(.addServerTapped)
      }
    }
  }
}
