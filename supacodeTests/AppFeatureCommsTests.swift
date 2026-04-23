import ComposableArchitecture
import Darwin
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureCommsTests {
  @Test(.dependencies) func conversationSendAppendsMessageSendsNotificationAndRespondsOK() async {
    let storage = SettingsTestStorage()
    let conversationsURL = FileManager.default.temporaryDirectory
      .appending(path: "conversations-\(UUID().uuidString).json", directoryHint: .notDirectory)
    let worktree = makeWorktree()
    let fixedDate = Date(timeIntervalSince1970: 1_718_760_000)
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let notifications = LockIsolated<[(String, String, URL?)]>([])
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.conversationsFileURL = conversationsURL
      $0.date.now = fixedDate
    } operation: {
      TestStore(
        initialState: AppFeature.State(
          repositories: makeRepositoriesState(worktree: worktree),
          settings: SettingsFeature.State(settings: globalSettings)
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.send = { title, body, deeplinkURL in
          notifications.withValue { $0.append((title, body, deeplinkURL)) }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .conversationSendRequested(
        ConversationSendRequest(
          worktreeID: worktree.id,
          senderName: "pi",
          title: "Need input",
          body: "Approve the release?"
        ),
        responseFD: writeFD
      )
    )
    await store.finish()

    let messages = store.state.conversations.messages(for: worktree.id)
    #expect(messages.count == 1)
    #expect(messages.first?.sender.name == "pi")
    #expect(messages.first?.title == "Need input")
    #expect(messages.first?.body == "Approve the release?")
    #expect(messages.first?.createdAt == fixedDate)

    #expect(notifications.value.count == 1)
    #expect(notifications.value.first?.0 == "Need input")
    #expect(notifications.value.first?.1 == "pi — Approve the release?")
    #expect(notifications.value.first?.2?.absoluteString == worktreeDeeplinkURL(for: worktree))

    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func conversationSendWritesErrorForUnknownWorktree() async {
    let storage = SettingsTestStorage()
    let conversationsURL = FileManager.default.temporaryDirectory
      .appending(path: "conversations-\(UUID().uuidString).json", directoryHint: .notDirectory)
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }

    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.conversationsFileURL = conversationsURL
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      }
    }
    store.exhaustivity = .off

    await store.send(
      .conversationSendRequested(
        ConversationSendRequest(
          worktreeID: "/tmp/unknown",
          senderName: "pi",
          title: "Need input",
          body: "Approve the release?"
        ),
        responseFD: writeFD
      )
    )
    await store.finish()

    #expect(store.state.conversations.threadsByWorktreeID.isEmpty)
    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect(response?["error"] as? String == "Worktree not found: /tmp/unknown")
  }

  private func makeWorktree() -> Worktree {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let workingDirectory = rootURL.appending(path: "wt-1", directoryHint: .isDirectory)
    return Worktree(
      id: workingDirectory.standardizedFileURL.path(percentEncoded: false),
      name: "wt-1",
      detail: "feat/comms",
      workingDirectory: workingDirectory,
      repositoryRootURL: rootURL
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [
      Repository(
        id: worktree.repositoryRootURL.standardizedFileURL.path(percentEncoded: false),
        rootURL: worktree.repositoryRootURL,
        name: "repo",
        worktrees: [worktree]
      )
    ]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true
    return repositoriesState
  }

  private func worktreeDeeplinkURL(for worktree: Worktree) -> String {
    let percentEncodingSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    let encodedWorktreeID =
      worktree.id.addingPercentEncoding(withAllowedCharacters: percentEncodingSet) ?? worktree.id
    return "supacode://worktree/\(encodedWorktreeID)"
  }

  private func makePipe() -> (readFD: Int32, writeFD: Int32) {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { buf in
      Darwin.pipe(buf.baseAddress!)
    }
    precondition(result == 0, "pipe() failed")
    return (fds[0], fds[1])
  }

  private func readPipeJSON(_ fileDescriptor: Int32) -> [String: Any]? {
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
