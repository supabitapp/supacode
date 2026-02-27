import ComposableArchitecture
import Foundation

struct MobileTerminalClient: Sendable {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>

  enum Command: Equatable, Sendable {
    case openSession(MobileServer, commandOverride: String?, identityFilePath: String?)
    case closeSession(UUID)
    case setSelectedServerID(MobileServer.ID?)
    case setAppFocus(Bool)
  }

  enum Event: Equatable, Sendable {
    case sessionOpened(id: UUID, serverID: MobileServer.ID, title: String)
    case sessionClosed(id: UUID)
    case sessionTitleChanged(id: UUID, title: String)
    case sessionProcessExited(id: UUID)
    case connectionFailed(serverID: MobileServer.ID, reason: String)
  }
}

extension MobileTerminalClient: DependencyKey {
  static let liveValue = MobileTerminalClient(
    send: { _ in fatalError("MobileTerminalClient.send not configured") },
    events: { fatalError("MobileTerminalClient.events not configured") }
  )

  static let testValue = MobileTerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var mobileTerminalClient: MobileTerminalClient {
    get { self[MobileTerminalClient.self] }
    set { self[MobileTerminalClient.self] = newValue }
  }
}
