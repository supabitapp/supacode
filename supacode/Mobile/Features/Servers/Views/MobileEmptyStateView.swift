import SwiftUI

struct MobileEmptyStateView: View {
  let onAddServer: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Servers", systemImage: "server.rack")
    } description: {
      Text("Add a server to get started with SSH sessions.")
    } actions: {
      Button("Add Server", systemImage: "plus") {
        onAddServer()
      }
      .buttonStyle(.borderedProminent)
    }
  }
}
