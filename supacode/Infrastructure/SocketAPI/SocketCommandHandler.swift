import Foundation

@MainActor
final class SocketCommandHandler {
  private enum Resolution<Value> {
    case success(Value)
    case failure(SocketResponse)
  }

  private let terminalManager: WorktreeTerminalManager

  init(terminalManager: WorktreeTerminalManager) {
    self.terminalManager = terminalManager
  }

  func handle(_ request: SocketRequest) -> SocketResponse {
    switch request.parsedMethod {
    case .systemPing:
      return .success(id: request.id, result: .object(["pong": .bool(true)]))
    case .tabList:
      return handleTabList(request)
    case .tabCreate:
      return handleTabCreate(request)
    case .tabClose:
      return handleTabClose(request)
    case .splitCreate:
      return handleSplitCreate(request)
    case .splitClose:
      return handleSplitClose(request)
    case nil:
      return .failure(
        id: request.id,
        code: .methodNotFound,
        message: "Unknown method: \(request.method)"
      )
    }
  }

  private func handleTabList(_ request: SocketRequest) -> SocketResponse {
    switch resolveState(for: request) {
    case .success(let state):
      let selectedTabID = state.tabManager.selectedTabId
      let tabs = state.tabManager.tabs.map { tab in
        SocketValue.object([
          "tab_id": .string(tab.id.rawValue.uuidString),
          "title": .string(tab.title),
          "is_selected": .bool(tab.id == selectedTabID),
        ])
      }
      return .success(id: request.id, result: .object(["tabs": .array(tabs)]))
    case .failure(let response):
      return response
    }
  }

  private func handleTabCreate(_ request: SocketRequest) -> SocketResponse {
    switch resolveStateAndParams(for: request) {
    case .success(let (state, params)):
      switch optionalString(for: "input", in: params, request: request) {
      case .success(let input):
        guard let tabID = state.createTab(initialInput: input) else {
          return .failure(
            id: request.id,
            code: .operationFailed,
            message: "Unable to create tab"
          )
        }
        return .success(id: request.id, result: .object(["tab_id": .string(tabID.rawValue.uuidString)]))
      case .failure(let response):
        return response
      }
    case .failure(let response):
      return response
    }
  }

  private func handleTabClose(_ request: SocketRequest) -> SocketResponse {
    switch resolveStateAndParams(for: request) {
    case .success(let (state, params)):
      switch optionalString(for: "tab_id", in: params, request: request) {
      case .success(let tabID):
        if let tabID {
          guard let tabUUID = UUID(uuidString: tabID) else {
            return .failure(
              id: request.id,
              code: .invalidParams,
              message: "tab_id must be a UUID string"
            )
          }
          guard state.tabManager.tabs.contains(where: { $0.id.rawValue == tabUUID }) else {
            return .failure(
              id: request.id,
              code: .operationFailed,
              message: "Tab not found"
            )
          }
          state.closeTab(TerminalTabID(rawValue: tabUUID))
        } else {
          guard state.closeFocusedTab() else {
            return .failure(
              id: request.id,
              code: .operationFailed,
              message: "No focused tab to close"
            )
          }
        }
        return .success(id: request.id, result: .object(["did_close": .bool(true)]))
      case .failure(let response):
        return response
      }
    case .failure(let response):
      return response
    }
  }

  private func handleSplitCreate(_ request: SocketRequest) -> SocketResponse {
    switch resolveStateAndParams(for: request) {
    case .success(let (state, params)):
      switch requiredString(for: "direction", in: params, request: request) {
      case .success(let direction):
        guard let splitDirection = splitDirection(from: direction) else {
          return .failure(
            id: request.id,
            code: .invalidParams,
            message: "direction must be one of: left, right, top, down"
          )
        }
        guard state.createSplitOnFocusedSurface(direction: splitDirection) else {
          return .failure(
            id: request.id,
            code: .operationFailed,
            message: "Unable to create split from the focused surface"
          )
        }
        return .success(id: request.id, result: .object(["did_split": .bool(true)]))
      case .failure(let response):
        return response
      }
    case .failure(let response):
      return response
    }
  }

  private func handleSplitClose(_ request: SocketRequest) -> SocketResponse {
    switch resolveState(for: request) {
    case .success(let state):
      guard state.closeFocusedSurface() else {
        return .failure(
          id: request.id,
          code: .operationFailed,
          message: "No focused split to close"
        )
      }
      return .success(id: request.id, result: .object(["did_close": .bool(true)]))
    case .failure(let response):
      return response
    }
  }

  private func resolveState(for request: SocketRequest) -> Resolution<WorktreeTerminalState> {
    switch resolveStateAndParams(for: request) {
    case .success(let value):
      return .success(value.state)
    case .failure(let response):
      return .failure(response)
    }
  }

  private func resolveStateAndParams(for request: SocketRequest)
    -> Resolution<(state: WorktreeTerminalState, params: [String: SocketValue])>
  {
    guard let params = request.params else {
      return .failure(
        .failure(
          id: request.id,
          code: .invalidParams,
          message: "Missing params object"
        )
      )
    }

    switch requiredString(for: "worktree_id", in: params, request: request) {
    case .success(let worktreeID):
      guard let state = terminalManager.stateIfExists(for: worktreeID) else {
        return .failure(
          .failure(
            id: request.id,
            code: .worktreeNotFound,
            message: "No terminal state exists for worktree_id: \(worktreeID)"
          )
        )
      }
      return .success((state, params))
    case .failure(let response):
      return .failure(response)
    }
  }

  private func requiredString(
    for key: String,
    in params: [String: SocketValue],
    request: SocketRequest
  ) -> Resolution<String> {
    guard let value = params[key] else {
      return .failure(
        .failure(
          id: request.id,
          code: .invalidParams,
          message: "Missing required param: \(key)"
        )
      )
    }

    guard let stringValue = value.stringValue else {
      return .failure(
        .failure(
          id: request.id,
          code: .invalidParams,
          message: "Param \(key) must be a string"
        )
      )
    }

    if stringValue.isEmpty {
      return .failure(
        .failure(
          id: request.id,
          code: .invalidParams,
          message: "Param \(key) must not be empty"
        )
      )
    }

    return .success(stringValue)
  }

  private func optionalString(
    for key: String,
    in params: [String: SocketValue],
    request: SocketRequest
  ) -> Resolution<String?> {
    guard let value = params[key] else {
      return .success(nil)
    }

    if case .null = value {
      return .success(nil)
    }

    guard let stringValue = value.stringValue else {
      return .failure(
        .failure(
          id: request.id,
          code: .invalidParams,
          message: "Param \(key) must be a string when provided"
        )
      )
    }

    return .success(stringValue)
  }

  private func splitDirection(from direction: String) -> GhosttySplitAction.NewDirection? {
    switch direction {
    case "left":
      return .left
    case "right":
      return .right
    case "top":
      return .top
    case "down":
      return .down
    default:
      return nil
    }
  }
}
