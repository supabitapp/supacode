import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct MobileAppFeature {
  @ObservableState
  struct State: Equatable {
    var servers = MobileServersFeature.State()
    var selectedServerID: MobileServer.ID?
    var sessions: IdentifiedArrayOf<MobileSession> = []
    var selectedSessionID: MobileSession.ID?
    @Presents var serverForm: ServerFormFeature.State?
    var backgroundTaskActive = false
  }

  enum Action {
    case task
    case servers(MobileServersFeature.Action)
    case serverForm(PresentationAction<ServerFormFeature.Action>)
    case terminalEvent(MobileTerminalClient.Event)
    case scenePhaseChanged(ScenePhase)
    case selectServer(MobileServer.ID?)
    case selectSession(MobileSession.ID?)
    case addServerTapped
    case editServerTapped(MobileServer)
    case openSession(commandOverride: String?)
    case closeSession(MobileSession.ID)
    case switchToSession(Int)
  }

  @Dependency(MobileTerminalClient.self) private var terminalClient

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
        if state.selectedServerID == id {
          state.selectedServerID = state.servers.servers.first?.id
        }
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
          state.selectedSessionID = sessionsForSelectedServer(state).last?.id
        }
        return .none

      case .terminalEvent(.sessionTitleChanged(let id, let title)):
        state.sessions[id: id]?.title = title
        return .none

      case .terminalEvent(.sessionProcessExited(let id)):
        state.sessions[id: id]?.isClosed = true
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

      case .selectServer(let id):
        state.selectedServerID = id
        if let id {
          state.selectedSessionID = sessionsForServer(id, state).first?.id
          return .run { [terminalClient] _ in
            await MainActor.run { terminalClient.send(.setSelectedServerID(id)) }
          }
        }
        return .none

      case .selectSession(let id):
        state.selectedSessionID = id
        return .none

      case .addServerTapped:
        state.serverForm = ServerFormFeature.State(mode: .add)
        return .none

      case .editServerTapped(let server):
        state.serverForm = ServerFormFeature.State(mode: .edit(server))
        return .none

      case .openSession(let commandOverride):
        guard let serverID = state.selectedServerID,
          let server = state.servers.servers[id: serverID]
        else { return .none }
        return .run { [terminalClient] _ in
          await MainActor.run { terminalClient.send(.openSession(server, commandOverride: commandOverride)) }
        }

      case .closeSession(let id):
        return .run { [terminalClient] _ in
          await MainActor.run { terminalClient.send(.closeSession(id)) }
        }

      case .switchToSession(let index):
        let sessions = sessionsForSelectedServer(state)
        guard index >= 0, index < sessions.count else { return .none }
        state.selectedSessionID = sessions[index].id
        return .none
      }
    }
    .ifLet(\.$serverForm, action: \.serverForm) {
      ServerFormFeature()
    }
  }

  nonisolated private func sessionsForSelectedServer(_ state: State) -> [MobileSession] {
    guard let serverID = state.selectedServerID else { return [] }
    return sessionsForServer(serverID, state)
  }

  nonisolated private func sessionsForServer(
    _ serverID: MobileServer.ID,
    _ state: State,
  ) -> [MobileSession] {
    state.sessions.filter { $0.serverID == serverID }
  }
}
