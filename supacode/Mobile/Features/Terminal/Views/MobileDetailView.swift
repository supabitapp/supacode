import ComposableArchitecture
import SwiftUI

struct MobileDetailView: View {
  @Bindable var store: StoreOf<MobileAppFeature>
  let terminalManager: MobileTerminalSessionManager

  private var selectedServer: MobileServer? {
    guard let id = store.selectedServerID else { return nil }
    return store.servers.servers[id: id]
  }

  private var serverSessions: [MobileSession] {
    guard let id = store.selectedServerID else { return [] }
    return store.sessions.filter { $0.serverID == id }.elements
  }

  private var selectedSession: MobileTerminalSession? {
    guard let id = store.selectedSessionID else { return nil }
    return terminalManager.session(for: id)
  }

  var body: some View {
    VStack(spacing: 0) {
      if !serverSessions.isEmpty {
        MobileTerminalTabBarView(
          sessions: serverSessions,
          selectedSessionID: store.selectedSessionID,
          onSelectSession: { id in
            store.send(.selectSession(id))
          },
          onCloseSession: { id in
            store.send(.closeSession(id))
          },
          onNewSession: {
            store.send(.openSession(commandOverride: nil))
          },
        )

        MobileTerminalContentView(
          session: selectedSession,
        )
      } else {
        MobileServerWelcomeView(
          server: selectedServer,
          onOpenSession: {
            store.send(.openSession(commandOverride: nil))
          },
          onEditServer: {
            if let server = selectedServer {
              store.send(.editServerTapped(server))
            }
          },
        )
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        if let server = selectedServer {
          Text(server.displayName)
            .font(.headline)
        }
      }

      ToolbarItem(placement: .topBarTrailing) {
        Button("New Session", systemImage: "plus.rectangle") {
          store.send(.openSession(commandOverride: nil))
        }
        .help("New Session (⌘T)")
        .disabled(selectedServer == nil || !(selectedServer?.hostIsValid ?? false))
      }
    }
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MobileServerWelcomeView: View {
  let server: MobileServer?
  let onOpenSession: () -> Void
  let onEditServer: () -> Void

  var body: some View {
    if let server {
      VStack(spacing: 16) {
        Spacer()

        Image(systemName: "terminal")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)

        Text(server.displayName)
          .font(.title2)
          .fontWeight(.semibold)

        Text(server.detailLine)
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if !server.defaultCommand.isEmpty {
          Text("Default: \(server.defaultCommand)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 12) {
          Button("Open Terminal") {
            onOpenSession()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!server.hostIsValid || !server.portIsValid)

          Button("Edit Server") {
            onEditServer()
          }
          .buttonStyle(.bordered)
        }

        Spacer()
      }
      .frame(maxWidth: .infinity)
    }
  }
}
