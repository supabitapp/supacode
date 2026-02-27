import SwiftUI

struct MobileEmptyStateView: View {
  let onConnect: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Active Sessions", systemImage: "terminal")
    } description: {
      Text("Connect to a server to start a terminal session.")
    } actions: {
      Button("Connect to Server", systemImage: "server.rack") {
        onConnect()
      }
      .buttonStyle(.borderedProminent)
    }
  }
}
