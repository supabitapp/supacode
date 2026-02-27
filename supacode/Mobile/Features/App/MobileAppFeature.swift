import ComposableArchitecture
import Foundation
import SwiftUI
import UIKit

@Reducer
struct MobileAppFeature {
  @ObservableState
  struct State: Equatable {
    var servers = MobileServersFeature.State()
    var sessions: IdentifiedArrayOf<MobileSession> = []
    var selectedSessionID: MobileSession.ID?
    var showServerList = false
    @Presents var serverForm: ServerFormFeature.State?
    @Presents var connectionAlert: AlertState<Action.ConnectionAlert>?
    var backgroundTaskActive = false
  }

  enum Action {
    case task
    case servers(MobileServersFeature.Action)
    case serverForm(PresentationAction<ServerFormFeature.Action>)
    case terminalEvent(MobileTerminalClient.Event)
    case scenePhaseChanged(ScenePhase)
    case selectSession(MobileSession.ID?)
    case connectButtonTapped
    case serverListDismissed
    case connectToServer(MobileServer.ID)
    case addServerTapped
    case editServerTapped(MobileServer)
    case openSession(serverID: MobileServer.ID, commandOverride: String?)
    case closeSession(MobileSession.ID)
    case switchToSession(Int)
    case connectionAlert(PresentationAction<ConnectionAlert>)

    @CasePathable
    enum ConnectionAlert: Equatable {
      case editServer(MobileServer.ID)
    }
  }

  @Dependency(MobileTerminalClient.self) private var terminalClient
  @Dependency(\.keychainClient) private var keychainClient
  @Dependency(\.sshKeyClient) private var sshKeyClient

  var body: some ReducerOf<Self> {
    Scope(state: \.servers, action: \.servers) {
      MobileServersFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .send(.servers(.task)),
          .run { [terminalClient] send in
            let stream = await MainActor.run { terminalClient.events() }
            for await event in stream {
              await send(.terminalEvent(event))
            }
          }
        )

      case .servers(.delegate(.serverDeleted(let id))):
        let sessionIDs = state.sessions.filter { $0.serverID == id }.map(\.id)
        return .merge(
          sessionIDs.map { sessionID in
            .run { [terminalClient] _ in
              await MainActor.run { terminalClient.send(.closeSession(sessionID)) }
            }
          }
        )

      case .servers:
        return .none

      case .serverForm(.presented(.delegate(.saved(let server)))):
        state.serverForm = nil
        return .send(.servers(.upsert(server)))

      case .serverForm(.presented(.delegate(.deleted(let id)))):
        state.serverForm = nil
        return .send(.servers(.delete(id)))

      case .serverForm(.presented(.delegate(.cancelled))):
        state.serverForm = nil
        return .none

      case .serverForm:
        return .none

      case .terminalEvent(.sessionOpened(let id, let serverID, let title)):
        let session = MobileSession(id: id, serverID: serverID, title: title)
        state.sessions.append(session)
        state.selectedSessionID = id
        return .none

      case .terminalEvent(.sessionClosed(let id)):
        state.sessions.remove(id: id)
        if state.selectedSessionID == id {
          state.selectedSessionID = state.sessions.last?.id
        }
        return .none

      case .terminalEvent(.sessionTitleChanged(let id, let title)):
        state.sessions[id: id]?.title = title
        return .none

      case .terminalEvent(.sessionProcessExited(let id)):
        state.sessions[id: id]?.isClosed = true
        return .none

      case .terminalEvent(.connectionFailed(let serverID, let reason)):
        let serverName = state.servers.servers[id: serverID]?.displayName ?? "Server"
        state.connectionAlert = AlertState {
          TextState("Connection Failed")
        } actions: {
          ButtonState(action: .editServer(serverID)) {
            TextState("Edit Server")
          }
          ButtonState(role: .cancel) {
            TextState("OK")
          }
        } message: {
          TextState("\(serverName): \(reason)")
        }
        return .none

      case .scenePhaseChanged(let phase):
        switch phase {
        case .active:
          state.backgroundTaskActive = false
          return .run { [terminalClient] _ in
            await MainActor.run { terminalClient.send(.setAppFocus(true)) }
          }
        case .background:
          state.backgroundTaskActive = true
          return .run { [terminalClient] _ in
            await MainActor.run { terminalClient.send(.setAppFocus(false)) }
          }
        case .inactive:
          return .run { [terminalClient] _ in
            await MainActor.run { terminalClient.send(.setAppFocus(false)) }
          }
        @unknown default:
          return .none
        }

      case .selectSession(let id):
        state.selectedSessionID = id
        return .none

      case .connectButtonTapped:
        state.showServerList = true
        return .none

      case .serverListDismissed:
        state.showServerList = false
        return .none

      case .connectToServer(let serverID):
        state.showServerList = false
        return .send(.openSession(serverID: serverID, commandOverride: nil))

      case .addServerTapped:
        state.serverForm = ServerFormFeature.State(mode: .add)
        return .none

      case .editServerTapped(let server):
        state.serverForm = ServerFormFeature.State(mode: .edit(server))
        return .none

      case .openSession(let serverID, let commandOverride):
        guard let server = state.servers.servers[id: serverID]
        else { return .none }
        return .run { [terminalClient, keychainClient, sshKeyClient] send in
          var identityFilePath: String?
          switch server.authMethod {
          case .none:
            break
          case .password:
            if let password = try? keychainClient.getString("server.\(server.id.uuidString).password"),
              !password.isEmpty
            {
              await MainActor.run { UIPasteboard.general.string = password }
            }
          case .sshKey(let keyID):
            do {
              identityFilePath = try sshKeyClient.writeIdentityFile(keyID)
            } catch {
              await send(
                .terminalEvent(.connectionFailed(serverID: server.id, reason: "Failed to load SSH key: \(error.localizedDescription)"))
              )
              return
            }
          }
          await MainActor.run {
            terminalClient.send(.openSession(server, commandOverride: commandOverride, identityFilePath: identityFilePath))
          }
        }

      case .closeSession(let id):
        return .run { [terminalClient] _ in
          await MainActor.run { terminalClient.send(.closeSession(id)) }
        }

      case .switchToSession(let index):
        guard index >= 0, index < state.sessions.count else { return .none }
        state.selectedSessionID = state.sessions[index].id
        return .none

      case .connectionAlert(.presented(.editServer(let serverID))):
        guard let server = state.servers.servers[id: serverID] else { return .none }
        state.showServerList = true
        return .send(.editServerTapped(server))

      case .connectionAlert:
        return .none
      }
    }
    .ifLet(\.$serverForm, action: \.serverForm) {
      ServerFormFeature()
    }
    .ifLet(\.$connectionAlert, action: \.connectionAlert)
  }
}
