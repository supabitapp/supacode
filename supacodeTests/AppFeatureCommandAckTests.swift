import ComposableArchitecture
import Darwin
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// Coverage for completion-based CLI socket acks: a command holds its
/// response open until the operation is observably complete (or the timeout
/// watchdog fires), then drains the client fd.
@MainActor
struct AppFeatureCommandAckTests {
  // MARK: - Transport.

  @Test func setCloseOnExecMarksDescriptor() {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { buf in
      socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress!)
    }
    precondition(result == 0, "socketpair() failed")
    defer {
      close(fds[0])
      close(fds[1])
    }
    #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC == 0)
    AgentHookSocketServer.setCloseOnExec(fds[0])
    #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC != 0)
  }

  // MARK: - tab new.

  @Test(.dependencies) func tabNewSocketDeeplinkResolvesOnProjection() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let store = makeStore(worktree: worktree, tabExists: false)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    // `timeoutSeconds: 0` skips the watchdog, so no clock is needed.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: tabID)),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await store.send(
      .terminalEvent(
        .tabProjectionChanged(
          worktreeID: worktree.id,
          WorktreeTabProjection(
            tabID: TerminalTabID(rawValue: tabID),
            surfaceIDs: [tabID],
            activeSurfaceID: tabID,
            unseenNotificationCount: 0
          )
        )
      )
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func tabNewSocketDeeplinkDrainsOnTimeout() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree, tabExists: false)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    // `timeoutSeconds: 0` skips the watchdog so the drain path is exercised
    // deterministically by dispatching the timeout action directly.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: UUID())),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    let token = store.state.pendingCommandAcks[id: writeFD]?.token
    #expect(token != nil)

    await store.send(.commandAckTimedOut(responseFD: writeFD, token: token ?? 0))
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.isEmpty == false)
  }

  @Test(.dependencies) func staleTimeoutWithMismatchedTokenIsIgnored() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree, tabExists: false)
    let (readFD, writeFD) = makePipe()
    defer {
      close(readFD)
      close(writeFD)
    }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: UUID())),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    let token = store.state.pendingCommandAcks[id: writeFD]?.token
    #expect(token != nil)

    // A watchdog from a prior ack that recycled this fd number must not drain
    // the live ack.
    await store.send(.commandAckTimedOut(responseFD: writeFD, token: (token ?? 0) + 1))
    await store.finish()
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)
  }

  // MARK: - worktree new.

  @Test(.dependencies) func worktreeNewAckBindsByPendingIDAndResolvesOnFirstTab() async {
    let worktree = makeWorktree()
    let created = Worktree(
      id: WorktreeID("/tmp/repo/wt-new"),
      name: "wt-new",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-new"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    let pendingID = WorktreeID("pending:cli-99")
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.pendingCommandAcks[id: writeFD] = AppFeature.PendingCommandAck(
      responseFD: writeFD, token: 1,
      match: .worktreeNew(pendingID: pendingID, worktreeID: nil))
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    // Creation success binds the ack (by pending id) to the real worktree id;
    // a sibling creation in the same repo (different pending id) is untouched.
    await store.send(
      .repositories(
        .createRandomWorktreeSucceeded(created, repositoryID: "/tmp/repo", pendingID: pendingID)))
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await store.send(.terminalEvent(.tabCreated(worktreeID: created.id)))
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == true)
    // The ack returns the created worktree id, percent-encoded like `worktree list`.
    let expectedID = created.id.rawValue.addingPercentEncoding(
      withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/")))
    #expect(response?["id"] as? String == expectedID)
  }

  @Test(.dependencies) func worktreeNewAckFailsByPendingID() async {
    let worktree = makeWorktree()
    let pendingID = WorktreeID("pending:cli-77")
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.pendingCommandAcks[id: writeFD] = AppFeature.PendingCommandAck(
      responseFD: writeFD, token: 1,
      match: .worktreeNew(pendingID: pendingID, worktreeID: nil))
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    await store.send(
      .repositories(
        .createRandomWorktreeFailed(
          title: "Failed", message: "boom", pendingID: pendingID,
          previousSelection: nil, repositoryID: "/tmp/repo", name: nil,
          baseDirectory: URL(fileURLWithPath: "/tmp/repo"))))
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect(response?["error"] as? String == "boom")
  }

  @Test(.dependencies) func worktreeNewAckDrainsOnPromptCancel() async {
    let worktree = makeWorktree()
    let pendingID = WorktreeID("pending:cli-55")
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.pendingCommandAcks[id: writeFD] = AppFeature.PendingCommandAck(
      responseFD: writeFD, token: 1,
      match: .worktreeNew(pendingID: pendingID, worktreeID: nil))
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    // Cancelling the creation prompt drains the parked ack as a failure.
    await store.send(.repositories(.cliWorktreeAckCancelled(pendingID: pendingID)))
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == false)
  }

  // MARK: - duplicate creation id.

  @Test(.dependencies) func duplicateCreationIdIsRejected() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let store = makeStore(worktree: worktree, tabExists: false)
    let (readFD1, writeFD1) = makePipe()
    let (readFD2, writeFD2) = makePipe()
    defer {
      close(readFD1)
      close(writeFD1)
      close(readFD2)
    }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: tabID)),
        source: .socket, responseFD: writeFD1, timeoutSeconds: 0))
    #expect(store.state.pendingCommandAcks[id: writeFD1] != nil)

    // A second creation reusing the same explicit id is rejected up front, so it
    // can't have the first creation's projection resolve its ack.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: nil, id: tabID)),
        source: .socket, responseFD: writeFD2, timeoutSeconds: 0))
    await store.finish()

    #expect(store.state.pendingCommandAcks[id: writeFD2] == nil)
    #expect(readPipeJSON(readFD2)?["ok"] as? Bool == false)
  }

  // MARK: - confirmation timeout.

  @Test(.dependencies) func confirmationTimeoutDrainsFd() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id, worktreeName: "wt-1", repositoryName: "repo",
      message: .confirmation("Delete?"), action: .delete,
      responseFD: writeFD, timeoutSeconds: 1, timeoutToken: 7)
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.deeplinkConfirmationTimedOut(responseFD: writeFD, token: 7))
    await store.finish()

    #expect(store.state.deeplinkInputConfirmation == nil)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == false)
  }

  @Test(.dependencies) func staleConfirmationTimeoutIsIgnored() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer {
      close(readFD)
      close(writeFD)
    }

    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.deeplinkInputConfirmation = DeeplinkInputConfirmationFeature.State(
      worktreeID: worktree.id, worktreeName: "wt-1", repositoryName: "repo",
      message: .confirmation("Delete?"), action: .delete,
      responseFD: writeFD, timeoutSeconds: 1, timeoutToken: 8)
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    // A watchdog from a prior dialog that recycled this fd must not close the
    // live dialog.
    await store.send(.deeplinkConfirmationTimedOut(responseFD: writeFD, token: 7))
    await store.finish()

    #expect(store.state.deeplinkInputConfirmation != nil)
  }

  // MARK: - tab close.

  @Test(.dependencies) func tabCloseSocketDeeplinkResolvesOnTabRemoved() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let store = makeStore(worktree: worktree, tabExists: true)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabDestroy(tabID: tabID)),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await store.send(
      .terminalEvent(.tabRemoved(worktreeID: worktree.id, tabID: TerminalTabID(rawValue: tabID)))
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  // MARK: - surface close.

  @Test(.dependencies) func surfaceCloseSocketDeeplinkResolvesOnSurfacesClosed() async {
    let worktree = makeWorktree()
    let surfaceID = UUID()
    // `.surfacesClosed` fans out to the agent-presence persist effect (a
    // debounced clock sleep), so drive it with an immediate clock and stub the
    // save so `store.finish()` isn't left with an in-flight effect.
    let store = makeStore(worktree: worktree, tabExists: true) {
      $0.continuousClock = ImmediateClock()
      $0.terminalClient.saveLayoutsWithAgents = { _ in }
    }
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surfaceDestroy(tabID: UUID(), surfaceID: surfaceID)),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await store.send(.terminalEvent(.surfacesClosed(worktreeID: worktree.id, [surfaceID])))
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  // MARK: - immediate ack.

  @Test(.dependencies) func synchronousCommandAcksImmediately() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree, tabExists: true)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    // Surface focus has no reliable completion signal, so it acks synchronously
    // without ever registering a pending ack.
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .surface(tabID: UUID(), surfaceID: UUID(), input: nil)),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func repeatedLockedTabRenameSocketDeeplinkFailsImmediately() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree, tabExists: true) {
      $0.terminalClient.tabCanRename = { _, _ in false }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    for _ in 0..<2 {
      let (readFD, writeFD) = makePipe()
      defer { close(readFD) }
      await store.send(
        .deeplink(
          .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review")),
          source: .socket,
          responseFD: writeFD,
          timeoutSeconds: 0
        )
      )
      await store.finish()
      let response = readPipeJSON(readFD)
      #expect(response?["ok"] as? Bool == false)
      #expect((response?["error"] as? String)?.localizedCaseInsensitiveContains("locked") == true)
    }
    #expect(store.state.alert != nil)
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func tabRenameSocketDeeplinkResolvesOnRenamedEvent() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(worktree: worktree, tabExists: true) {
      $0.terminalClient.tabCanRename = { _, _ in true }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review")),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await store.send(
      .terminalEvent(
        .tabRenamed(
          worktreeID: worktree.id, tabID: TerminalTabID(rawValue: tabID), applied: true))
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
    #expect(
      sent.value.contains(
        .renameTab(worktree, tabID: TerminalTabID(rawValue: tabID), title: "review")))
  }

  @Test(.dependencies) func tabRenameSocketDeeplinkFailsWhenRenameDoesNotApply() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let store = makeStore(worktree: worktree, tabExists: true) {
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review")),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    // The tab is closed between the guard and the terminal command.
    await store.send(
      .terminalEvent(
        .tabRenamed(
          worktreeID: worktree.id, tabID: TerminalTabID(rawValue: tabID), applied: false))
    )
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.localizedCaseInsensitiveContains("closed") == true)
  }

  @Test(.dependencies) func successfulSocketDeeplinkPreservesExistingAlert() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let store = makeStore(worktree: worktree, tabExists: true) {
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    let (failReadFD, failWriteFD) = makePipe()
    defer { close(failReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: "/tmp/gone/", action: .select),
        source: .socket,
        responseFD: failWriteFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()
    #expect(readPipeJSON(failReadFD)?["ok"] as? Bool == false)
    let raisedAlert = store.state.alert
    #expect(raisedAlert != nil)

    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review")),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    await store.send(
      .terminalEvent(
        .tabRenamed(
          worktreeID: worktree.id, tabID: TerminalTabID(rawValue: tabID), applied: true))
    )
    await store.finish()

    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
    // The command raised no alert of its own, so the one on screen survives.
    #expect(store.state.alert == raisedAlert)
  }

  @Test(.dependencies) func confirmedTabNewFailsWhenWorktreeVanishes() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in false }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    // An explicit id gives the command a completion match, so the ack would be
    // deferred (and never resolved) if the dispatch failure did not suppress it.
    let tabID = UUID()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "omp", id: tabID)),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.deeplinkInputConfirmation != nil)

    // The worktree is deleted while the confirmation dialog is open.
    await store.send(
      .repositories(
        .worktreeDeleted(
          worktree.id, repositoryID: "/tmp/repo", selectionWasRemoved: false, nextSelection: nil)
      )
    )
    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(
                worktreeID: worktree.id,
                action: .tabNew(input: "omp", id: tabID),
                alwaysAllow: false
              )
            )
          )
        )
      )
    }
    await store.finish()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.localizedCaseInsensitiveContains("worktree") == true)
    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(!sent.value.contains { if case .createTabWithInput = $0 { true } else { false } })
  }

  @Test(.dependencies) func commandAnswersWhileAnotherCommandsDialogIsOpen() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.tabCanRename = { _, _ in true }
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    // A shell-spawning command parks its fd on a confirmation dialog.
    let (dialogReadFD, dialogWriteFD) = makePipe()
    defer { close(dialogReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "omp", id: nil)),
        source: .socket,
        responseFD: dialogWriteFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.deeplinkInputConfirmation != nil)

    // A second command on its own fd must still be answered, not stranded.
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tab(tabID: UUID())),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()

    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func supersededDialogAnswersOnlyTheDisplacedCommand() async {
    let worktree = makeWorktree()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in false }
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    let (firstReadFD, firstWriteFD) = makePipe()
    defer { close(firstReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "one", id: nil)),
        source: .socket,
        responseFD: firstWriteFD,
        timeoutSeconds: 0
      )
    )

    // A second confirmable command supersedes the first one's dialog.
    let (secondReadFD, secondWriteFD) = makePipe()
    defer { close(secondReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "two", id: nil)),
        source: .socket,
        responseFD: secondWriteFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()

    let superseded = readPipeJSON(firstReadFD)
    #expect(superseded?["ok"] as? Bool == false)
    #expect((superseded?["error"] as? String)?.localizedCaseInsensitiveContains("superseded") == true)
    // The displacing command owns the dialog now, so its fd stays open for it.
    #expect(readPipeJSON(secondReadFD) == nil)
    #expect(store.state.deeplinkInputConfirmation?.responseFD == secondWriteFD)
  }

  @Test(.dependencies) func deferredAckIsNotAnsweredEarlyWhileAnotherDialogIsOpen() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, candidate in candidate.rawValue == tabID }
      $0.terminalClient.tabCanRename = { _, _ in true }
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    let (dialogReadFD, dialogWriteFD) = makePipe()
    defer { close(dialogReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabNew(input: "omp", id: nil)),
        source: .socket,
        responseFD: dialogWriteFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.deeplinkInputConfirmation != nil)

    // A rename dispatched alongside the open dialog defers to its own completion.
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review")),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)
    #expect(readPipeJSON(readFD) == nil)

    await store.send(
      .terminalEvent(
        .tabRenamed(
          worktreeID: worktree.id, tabID: TerminalTabID(rawValue: tabID), applied: true))
    )
    await store.finish()

    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func tabRenameSocketDeeplinkTimesOutWhenEventNeverArrives() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let clock = TestClock()
    let store = makeStore(worktree: worktree, tabExists: true) {
      $0.terminalClient.tabCanRename = { _, _ in true }
      $0.continuousClock = clock
    }
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabRename(tabID: tabID, title: "review")),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 1
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await clock.advance(by: .seconds(1))
    await store.finish()
    await store.skipReceivedActions()

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.localizedCaseInsensitiveContains("timed out") == true)
    #expect(store.state.pendingCommandAcks.isEmpty)
  }

  @Test(.dependencies) func confirmedTabCloseFailsWhenTabVanishesWithMatchingAlert() async {
    let worktree = makeWorktree()
    let tabID = UUID()
    let tabExists = LockIsolated(false)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var settings = SettingsFeature.State()
    settings.automatedActionPolicy = .never
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: settings
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in tabExists.value }
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }
    store.exhaustivity = .off

    let (priorReadFD, priorWriteFD) = makePipe()
    defer { close(priorReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tab(tabID: tabID)),
        source: .socket,
        responseFD: priorWriteFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()
    #expect(readPipeJSON(priorReadFD)?["ok"] as? Bool == false)
    #expect(store.state.alert != nil)

    tabExists.withValue { $0 = true }
    let (closeReadFD, closeWriteFD) = makePipe()
    defer { close(closeReadFD) }
    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .tabDestroy(tabID: tabID)),
        source: .socket,
        responseFD: closeWriteFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.deeplinkInputConfirmation != nil)

    tabExists.withValue { $0 = false }
    await withKnownIssue("TCA @Presents dismiss tracking") {
      await store.send(
        .deeplinkInputConfirmation(
          .presented(
            .delegate(
              .confirm(
                worktreeID: worktree.id,
                action: .tabDestroy(tabID: tabID),
                alwaysAllow: false
              )
            )
          )
        )
      )
    }
    await store.finish()

    let response = readPipeJSON(closeReadFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.localizedCaseInsensitiveContains("no tab matching") == true)
    #expect(!sent.value.contains { if case .destroyTab = $0 { true } else { false } })
  }

  // MARK: - worktree delete.

  @Test(.dependencies) func deleteSocketDeeplinkResolvesOnWorktreeDeleted() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree, tabExists: true)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .delete),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    await store.send(
      .repositories(
        .worktreeDeleted(
          worktree.id, repositoryID: "/tmp/repo", selectionWasRemoved: false, nextSelection: nil)
      )
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func deleteSocketDeeplinkFailsOnScriptCancellation() async {
    let worktree = makeWorktree()
    let store = makeStore(worktree: worktree, tabExists: true)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .delete),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)

    // Closing the delete-script tab reports a nil exit code (cancellation);
    // no `.worktreeDeleted` follows, so the ack must drain as a failure now.
    await store.send(
      .repositories(.deleteScriptCompleted(worktreeID: worktree.id, exitCode: nil, tabId: nil))
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == false)
  }

  @Test(.dependencies) func deleteSocketDeeplinkRejectsTerminatingWorktree() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    var repositoriesState = makeRepositoriesState(worktree: worktree)
    repositoriesState.reconcileSidebarForTesting()
    // A worktree already winding down no-ops in the reducer, so registering an
    // ack would strand the client: the command is rejected up front instead.
    repositoriesState.sidebarItems[id: worktree.id]?.lifecycle = .deleting
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState, settings: SettingsFeature.State())
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(
      .deeplink(
        .worktree(id: worktree.id, action: .delete),
        source: .socket,
        responseFD: writeFD,
        timeoutSeconds: 0
      )
    )
    await store.finish()

    #expect(store.state.pendingCommandAcks.isEmpty)
    #expect(store.state.alert != nil)
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == false)
  }

  // MARK: - folder delete.

  // Note: the success / failure outcomes of `repositoryRemovalCompleted` flow
  // through the removal aggregator, which requires a seeded removal batch
  // (the real confirm path always seeds one). The core resolver is a plain
  // switch over the outcome; its matching and drain are covered by the cancel
  // test below and the surface-split-failure test.
  @Test(.dependencies) func folderDeleteAckDrainsOnCancel() async {
    let store = makeFolderAckStore(match: .folderRemoved(repositoryID: "/tmp/repo"))
    defer { close(store.readFD) }

    await store.store.send(.repositories(.alert(.dismiss)))
    await store.store.finish()

    #expect(store.store.state.pendingCommandAcks.isEmpty)
    #expect(readPipeJSON(store.readFD)?["ok"] as? Bool == false)
  }

  @Test(.dependencies) func folderDeleteAckSurvivesUnrelatedDismissOnceRemoving() async {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    defer {
      close(readFD)
      close(writeFD)
    }
    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.pendingCommandAcks[id: writeFD] = AppFeature.PendingCommandAck(
      responseFD: writeFD, token: 1, match: .folderRemoved(repositoryID: "/tmp/repo"))
    // Past confirmation: removal is in flight, so an unrelated alert dismissal
    // must not cancel the ack (it resolves on `repositoryRemovalCompleted`).
    initial.repositories.removingRepositoryIDs["/tmp/repo"] =
      RepositoriesFeature.RepositoryRemovalRecord(disposition: .folderTrash, batchID: UUID())
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.repositories(.alert(.dismiss)))
    await store.finish()

    #expect(store.state.pendingCommandAcks[id: writeFD] != nil)
  }

  // MARK: - surface split failure.

  @Test(.dependencies) func surfaceSplitFailureDrainsAck() async {
    let worktree = makeWorktree()
    let surfaceID = UUID()
    let store = makeFolderAckStore(
      match: .surfaceSplit(worktreeID: worktree.id, surfaceID: surfaceID))
    defer { close(store.readFD) }

    await store.store.send(
      .terminalEvent(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: surfaceID, message: "Could not create the split surface."
        )))
    await store.store.finish()

    #expect(store.store.state.pendingCommandAcks.isEmpty)
    let response = readPipeJSON(store.readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect((response?["error"] as? String)?.isEmpty == false)
  }

  // MARK: - Helpers.

  /// Builds a store with a single pending ack pre-seeded, returning it with the
  /// pipe read end so the test can assert the drained response.
  private func makeFolderAckStore(
    match: AppFeature.CompletionMatch
  ) -> (store: TestStoreOf<AppFeature>, readFD: Int32) {
    let worktree = makeWorktree()
    let (readFD, writeFD) = makePipe()
    var initial = AppFeature.State(
      repositories: makeRepositoriesState(worktree: worktree),
      settings: SettingsFeature.State()
    )
    initial.pendingCommandAcks[id: writeFD] = AppFeature.PendingCommandAck(
      responseFD: writeFD, token: 1, match: match)
    let store = TestStore(initialState: initial) { AppFeature() }
    store.exhaustivity = .off
    return (store, readFD)
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt-1"),
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true
    return repositoriesState
  }

  private func makeStore(
    worktree: Worktree,
    tabExists: Bool,
    _ extraDependencies: (inout DependencyValues) -> Void = { _ in }
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in tabExists }
      $0.terminalClient.surfaceExists = { _, _, _ in tabExists }
      $0.terminalClient.surfaceExistsInWorktree = { _, _ in tabExists }
      $0.terminalClient.send = { _ in }
      extraDependencies(&$0)
    }
    store.exhaustivity = .off
    return store
  }

  private func makePipe() -> (readFD: Int32, writeFD: Int32) {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { buf in
      Darwin.pipe(buf.baseAddress!)
    }
    precondition(result == 0, "pipe() failed")
    return (fds[0], fds[1])
  }

  /// Nil when the command left the fd unanswered. The read is non-blocking so an
  /// unanswered fd fails its test instead of wedging the suite on a blocked read.
  private func readPipeJSON(_ fileDescriptor: Int32) -> [String: Any]? {
    _ = fcntl(fileDescriptor, F_SETFL, fcntl(fileDescriptor, F_GETFL) | O_NONBLOCK)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let bytesRead = buffer.withUnsafeMutableBufferPointer { buf in
        Darwin.read(fileDescriptor, buf.baseAddress!, buf.count)
      }
      guard bytesRead > 0 else { break }
      data.append(contentsOf: buffer.prefix(bytesRead))
    }
    guard !data.isEmpty else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
