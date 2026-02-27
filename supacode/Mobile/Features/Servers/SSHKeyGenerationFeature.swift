import ComposableArchitecture
import Foundation
import UIKit

@Reducer
struct SSHKeyGenerationFeature {
  @ObservableState
  struct State: Equatable {
    var keyName = ""
    var generatedKey: SSHKey?
    var publicKey: String?
    var fingerprint: String?
    var isGenerating = false
    var error: String?
    var copied = false

    var canGenerate: Bool {
      !keyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var showResult: Bool {
      generatedKey != nil
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case generateTapped
    case generateResult(Result<SSHKey, Error>)
    case copyPublicKeyTapped
    case doneTapped
    case delegate(Delegate)

    enum Delegate: Equatable {
      case keyGenerated(SSHKey)
    }
  }

  @Dependency(\.sshKeyClient) private var sshKeyClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.error = nil
        state.copied = false
        return .none

      case .generateTapped:
        let name = state.keyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        state.isGenerating = true
        state.error = nil
        return .run { [sshKeyClient] send in
          let result = Result { try sshKeyClient.generate(name) }
          await send(.generateResult(result))
        }

      case .generateResult(.success(let key)):
        state.isGenerating = false
        state.generatedKey = key
        state.publicKey = key.publicKey
        state.fingerprint = key.fingerprint
        return .none

      case .generateResult(.failure(let error)):
        state.isGenerating = false
        state.error = error.localizedDescription
        return .none

      case .copyPublicKeyTapped:
        guard let publicKey = state.publicKey else { return .none }
        UIPasteboard.general.string = publicKey
        state.copied = true
        return .none

      case .doneTapped:
        guard let key = state.generatedKey else { return .none }
        return .send(.delegate(.keyGenerated(key)))

      case .delegate:
        return .none
      }
    }
  }
}
