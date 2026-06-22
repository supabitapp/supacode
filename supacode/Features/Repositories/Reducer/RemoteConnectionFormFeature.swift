import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Add / edit form for a remote (SSH) repository connection. Validation (ssh
/// reachability + `~` expansion to an absolute path) runs in-feature so an
/// error surfaces in the sheet footer and the sheet stays open on failure,
/// mirroring the worktree-creation prompt. The display name is intentionally
/// absent: a remote repo is renamed through Customize Appearance like any other.
@Reducer
struct RemoteConnectionFormFeature {
  @ObservableState
  struct State: Equatable {
    enum Mode: Equatable {
      case add
      /// Editing an existing remote, keyed by its self-descriptive repository id.
      /// The original id is kept so the parent can replace it and drop stale
      /// per-repo customization when a host/path change re-keys the repo.
      case edit(originalRepositoryID: Repository.ID)
    }

    var mode: Mode
    var server: String
    var port: String
    var username: String
    var remotePath: String
    var validationMessage: String?
    var isValidating = false

    init(
      mode: Mode = .add,
      server: String = "",
      port: String = "",
      username: String = "",
      remotePath: String = ""
    ) {
      self.mode = mode
      self.server = server
      self.port = port
      self.username = username
      self.remotePath = remotePath
    }

    /// Seed an edit form from an existing remote host + path.
    static func editing(host: RemoteHost, remotePath: String, repositoryID: Repository.ID) -> State {
      State(
        mode: .edit(originalRepositoryID: repositoryID),
        server: host.alias,
        port: host.port.map(String.init) ?? "",
        username: host.username ?? "",
        remotePath: remotePath
      )
    }

    var trimmedServer: String { server.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPath: String { remotePath.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEditing: Bool { if case .edit = mode { true } else { false } }
    var canSubmit: Bool { !trimmedServer.isEmpty && !trimmedPath.isEmpty && !isValidating }

    func makeHost() -> RemoteHost {
      let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
      return RemoteHost(
        alias: trimmedServer,
        username: trimmedUser.isEmpty ? nil : trimmedUser,
        port: Int(trimmedPort)
      )
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case submitButtonTapped
    case cancelButtonTapped
    /// `nil` absolute path means the host was unreachable or the path is missing.
    case resolutionFinished(absolutePath: String?)
    case delegate(Delegate)

    enum Delegate: Equatable {
      /// A validated host + resolved absolute path; the parent derives the id,
      /// persists it (add or replace), and dismisses.
      case save(host: RemoteHost, remotePath: String)
      case cancel
    }
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        // Any edit clears the last failure so a stale message doesn't linger.
        state.validationMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .submitButtonTapped:
        guard state.canSubmit else { return .none }
        state.isValidating = true
        state.validationMessage = nil
        let host = state.makeHost()
        let path = state.trimmedPath
        return .run { send in
          let absolute = await RepositoriesFeature.resolveRemotePath(path, host: host)
          await send(.resolutionFinished(absolutePath: absolute))
        }

      case .resolutionFinished(let absolutePath):
        state.isValidating = false
        guard let absolutePath else {
          state.validationMessage =
            "Couldn't reach \(state.makeHost().sshDestination) or find \(state.trimmedPath). "
            + "Check the server, port, user, and path."
          return .none
        }
        return .send(.delegate(.save(host: state.makeHost(), remotePath: absolutePath)))

      case .delegate:
        return .none
      }
    }
  }
}
