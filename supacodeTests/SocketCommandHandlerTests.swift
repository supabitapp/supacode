import Foundation
import Testing

@testable import supacode

@MainActor
struct SocketCommandHandlerTests {
  @Test func systemPingReturnsPong() {
    let handler = SocketCommandHandler(terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime()))

    let response = handler.handle(
      SocketRequest(id: "1", method: "system.ping", params: nil)
    )

    #expect(response.isSuccess == true)
    #expect(response.error == nil)
    #expect(response.id == "1")
    #expect(response.result == .object(["pong": .bool(true)]))
  }

  @Test func unknownMethodReturnsMethodNotFound() {
    let handler = SocketCommandHandler(terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime()))

    let response = handler.handle(
      SocketRequest(id: "2", method: "unknown.method", params: nil)
    )

    #expect(response.isSuccess == false)
    #expect(response.error?.code == SocketErrorCode.methodNotFound.rawValue)
  }

  @Test func missingParamsReturnsInvalidParams() {
    let handler = SocketCommandHandler(terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime()))

    let response = handler.handle(
      SocketRequest(id: "3", method: "tab.list", params: nil)
    )

    #expect(response.isSuccess == false)
    #expect(response.error?.code == SocketErrorCode.invalidParams.rawValue)
  }

  @Test func unknownWorktreeReturnsWorktreeNotFound() {
    let handler = SocketCommandHandler(terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime()))

    let response = handler.handle(
      SocketRequest(
        id: "4",
        method: "tab.list",
        params: [
          "worktree_id": .string("/tmp/repo/missing")
        ]
      )
    )

    #expect(response.isSuccess == false)
    #expect(response.error?.code == SocketErrorCode.worktreeNotFound.rawValue)
  }

  @Test func tabListReturnsTabsAndSelectionState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let firstTabID = state.tabManager.createTab(title: "First", icon: nil)
    _ = state.tabManager.createTab(title: "Second", icon: nil)
    state.tabManager.selectTab(firstTabID)

    let handler = SocketCommandHandler(terminalManager: manager)
    let response = handler.handle(
      SocketRequest(
        id: "5",
        method: "tab.list",
        params: [
          "worktree_id": .string(worktree.id)
        ]
      )
    )

    #expect(response.isSuccess == true)
    #expect(response.error == nil)

    guard
      case .object(let object)? = response.result,
      case .array(let tabs)? = object["tabs"],
      tabs.count == 2,
      case .object(let firstTab) = tabs[0],
      case .object(let secondTab) = tabs[1]
    else {
      Issue.record("Expected two tabs in tab.list result")
      return
    }

    #expect(firstTab["title"] == .string("First"))
    #expect(firstTab["is_selected"] == .bool(true))
    #expect(secondTab["title"] == .string("Second"))
    #expect(secondTab["is_selected"] == .bool(false))
  }

  @Test func splitCreateRejectsUnknownDirection() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    _ = manager.state(for: worktree)

    let handler = SocketCommandHandler(terminalManager: manager)
    let response = handler.handle(
      SocketRequest(
        id: "6",
        method: "split.create",
        params: [
          "worktree_id": .string(worktree.id),
          "direction": .string("up"),
        ]
      )
    )

    #expect(response.isSuccess == false)
    #expect(response.error?.code == SocketErrorCode.invalidParams.rawValue)
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }
}
