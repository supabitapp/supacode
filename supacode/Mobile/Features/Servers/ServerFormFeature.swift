import ComposableArchitecture
import Foundation

@Reducer
struct ServerFormFeature {
  @ObservableState
  struct State: Equatable {
    var mode: Mode
    var name: String
    var host: String
    var username: String
    var port: String
    var defaultCommand: String
    var validationError: String?

    enum Mode: Equatable {
      case add
      case edit(MobileServer)

      var serverID: MobileServer.ID? {
        switch self {
        case .add:
          nil
        case .edit(let server):
          server.id
        }
      }
    }

    var isEditing: Bool {
      if case .edit = mode { true } else { false }
    }

    var canSave: Bool {
      guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
      guard let portValue = Int(port), (1 ... 65535).contains(portValue) else { return false }
      return true
    }

    init(mode: Mode) {
      self.mode = mode
      switch mode {
      case .add:
        name = ""
        host = ""
        username = ""
        port = "22"
        defaultCommand = ""
      case .edit(let server):
        name = server.name
        host = server.host
        username = server.username
        port = "\(server.port)"
        defaultCommand = server.defaultCommand
      }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case save
    case delete
    case cancel
    case delegate(Delegate)

    enum Delegate: Equatable {
      case saved(MobileServer)
      case deleted(MobileServer.ID)
      case cancelled
    }
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.validationError = nil
        return .none

      case .save:
        guard state.canSave else {
          state.validationError = "Use a valid host and port between 1 and 65535."
          return .none
        }
        let serverID: UUID
        switch state.mode {
        case .add:
          serverID = UUID()
        case .edit(let server):
          serverID = server.id
        }
        let server = MobileServer(
          id: serverID,
          name: state.name,
          host: state.host,
          username: state.username,
          port: Int(state.port) ?? 22,
          defaultCommand: state.defaultCommand,
        )
        return .send(.delegate(.saved(server)))

      case .delete:
        guard let serverID = state.mode.serverID else { return .none }
        return .send(.delegate(.deleted(serverID)))

      case .cancel:
        return .send(.delegate(.cancelled))

      case .delegate:
        return .none
      }
    }
  }
}
