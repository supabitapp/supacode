import ComposableArchitecture
import SwiftUI

struct MobileDetailView: View {
  @Bindable var store: StoreOf<MobileAppFeature>
  let terminalManager: MobileTerminalSessionManager

  private var selectedSession: MobileSession? {
    guard let id = store.selectedSessionID else { return nil }
    return store.sessions[id: id]
  }

  private var selectedServer: MobileServer? {
    guard let session = selectedSession else { return nil }
    return store.servers.servers[id: session.serverID]
  }

  private var terminalSession: MobileTerminalSession? {
    guard let id = store.selectedSessionID else { return nil }
    return terminalManager.session(for: id)
  }

  var body: some View {
    VStack(spacing: 0) {
      MobileTerminalContentView(
        session: terminalSession,
      )
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        if let session = selectedSession {
          Text(session.title)
            .font(.headline)
            .monospaced()
        }
      }

      ToolbarItem(placement: .topBarTrailing) {
        if let session = selectedSession {
          Button("Close Session", systemImage: "xmark.circle") {
            store.send(.closeSession(session.id))
          }
          .help("Close Session (⌘W)")
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
  }
}
