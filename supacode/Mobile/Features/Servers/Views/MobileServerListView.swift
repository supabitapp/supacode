import ComposableArchitecture
import SwiftUI

struct MobileServerListView: View {
  @Bindable var store: StoreOf<MobileAppFeature>

  var body: some View {
    NavigationStack {
      List {
        if store.servers.servers.isEmpty {
          ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
          } description: {
            Text("Add a server to get started.")
          }
        } else {
          ForEach(store.servers.servers) { server in
            MobileServerListRow(
              server: server,
              onConnect: {
                store.send(.connectToServer(server.id))
              },
              onEdit: {
                store.send(.editServerTapped(server))
              },
            )
            .swipeActions(edge: .trailing) {
              Button("Delete", role: .destructive) {
                store.send(.servers(.delete(server.id)))
              }
              Button("Edit") {
                store.send(.editServerTapped(server))
              }
              .tint(.orange)
            }
          }
        }
      }
      .navigationTitle("Servers")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            store.send(.serverListDismissed)
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Add Server", systemImage: "plus") {
            store.send(.addServerTapped)
          }
          .help("Add Server")
        }
      }
      .sheet(item: $store.scope(state: \.serverForm, action: \.serverForm)) { formStore in
        MobileServerFormView(store: formStore)
      }
    }
  }
}

private struct MobileServerListRow: View {
  let server: MobileServer
  let onConnect: () -> Void
  let onEdit: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(server.displayName)
          .font(.body)
          .lineLimit(1)

        Text(server.detailLine)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        onEdit()
      } label: {
        Image(systemName: "pencil.circle")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Edit Server")

      Button {
        onConnect()
      } label: {
        Text("Connect")
          .font(.callout)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
      .disabled(!server.hostIsValid || !server.portIsValid)
    }
    .padding(.vertical, 2)
  }
}
