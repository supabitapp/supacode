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

    // Auth
    var authType: AuthType = .none
    var password: String = ""
    var availableKeys: [SSHKey] = []
    var selectedKeyID: SSHKey.ID?
    @Presents var keyGeneration: SSHKeyGenerationFeature.State?

    enum AuthType: String, CaseIterable, Equatable {
      case none = "None"
      case password = "Password"
      case sshKey = "SSH Key"
    }

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
      if authType == .sshKey && selectedKeyID == nil { return false }
      return true
    }

    var authMethod: SSHAuthMethod {
      switch authType {
      case .none:
        .none
      case .password:
        .password
      case .sshKey:
        if let keyID = selectedKeyID { .sshKey(keyID) } else { .none }
      }
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
        switch server.authMethod {
        case .none:
          authType = .none
        case .password:
          authType = .password
        case .sshKey(let keyID):
          authType = .sshKey
          selectedKeyID = keyID
        }
      }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case keysLoaded([SSHKey])
    case save
    case delete
    case cancel
    case generateKeyTapped
    case keyGeneration(PresentationAction<SSHKeyGenerationFeature.Action>)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case saved(MobileServer)
      case deleted(MobileServer.ID)
      case cancelled
    }
  }

  @Dependency(\.keychainClient) private var keychainClient
  @Dependency(\.sshKeyClient) private var sshKeyClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.authType):
        state.validationError = nil
        if state.authType != .password {
          state.password = ""
        }
        if state.authType != .sshKey {
          state.selectedKeyID = nil
        }
        return .none

      case .binding:
        state.validationError = nil
        return .none

      case .task:
        return .run { [sshKeyClient] send in
          let keys = sshKeyClient.loadAll()
          await send(.keysLoaded(keys))
        }

      case .keysLoaded(let keys):
        state.availableKeys = keys
        if state.authType == .password, case .edit(let server) = state.mode,
          case .password = server.authMethod
        {
          state.password = (try? keychainClient.getString("server.\(server.id.uuidString).password")) ?? ""
        }
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

        let authMethod = state.authMethod
        if case .password = authMethod {
          let trimmedPassword = state.password.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmedPassword.isEmpty {
            try? keychainClient.setString(trimmedPassword, "server.\(serverID.uuidString).password")
          }
        } else {
          try? keychainClient.delete("server.\(serverID.uuidString).password")
        }

        let server = MobileServer(
          id: serverID,
          name: state.name,
          host: state.host,
          username: state.username,
          port: Int(state.port) ?? 22,
          defaultCommand: state.defaultCommand,
          authMethod: authMethod,
        )
        return .send(.delegate(.saved(server)))

      case .delete:
        guard let serverID = state.mode.serverID else { return .none }
        try? keychainClient.delete("server.\(serverID.uuidString).password")
        return .send(.delegate(.deleted(serverID)))

      case .cancel:
        return .send(.delegate(.cancelled))

      case .generateKeyTapped:
        state.keyGeneration = SSHKeyGenerationFeature.State()
        return .none

      case .keyGeneration(.presented(.delegate(.keyGenerated(let key)))):
        state.keyGeneration = nil
        state.availableKeys.insert(key, at: 0)
        state.selectedKeyID = key.id
        state.authType = .sshKey
        return .none

      case .keyGeneration(.dismiss):
        state.keyGeneration = nil
        return .none

      case .keyGeneration:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$keyGeneration, action: \.keyGeneration) {
      SSHKeyGenerationFeature()
    }
  }
}
