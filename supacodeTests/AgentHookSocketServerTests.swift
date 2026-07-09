import ConcurrencyExtras
import Darwin
import Foundation
import Testing

@testable import supacode

@MainActor
struct AgentHookSocketServerTests {
  // MARK: - CLI protocol framing.

  @Test func nonJSONPayloadIsRejected() {
    // The socket carries only the CLI control protocol (JSON command / query).
    // Anything that is not a JSON object is dropped.
    let raw = "wt \(UUID().uuidString) \(UUID().uuidString) 1"
    #expect(AgentHookSocketServer.parse(data: Data(raw.utf8)) == nil)
  }

  @Test func emptyInputReturnsNil() {
    #expect(AgentHookSocketServer.parse(data: Data()) == nil)
  }

  @Test func whitespaceOnlyInputReturnsNil() {
    #expect(AgentHookSocketServer.parse(data: Data("   \n  \n  ".utf8)) == nil)
  }

  // MARK: - CLI command message parsing.

  @Test func parsesValidCommandMessage() {
    let json = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .command(let url, _) = message else {
      Issue.record("Expected command message, got \(String(describing: message))")
      return
    }
    #expect(url.scheme == "supacode")
    #expect(url.host() == "worktree")
  }

  @Test func rejectsCommandWithInvalidScheme() {
    let json = #"{"deeplink":"https://example.com"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func rejectsCommandWithMalformedJSON() {
    let json = #"{"not_deeplink":"supacode://test"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  // MARK: - Query message parsing.

  @Test func parsesValidQueryMessage() {
    let json = #"{"query":"repos"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, let params, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "repos")
    #expect(params.isEmpty)
  }

  @Test func parsesQueryMessageWithParams() {
    let json = #"{"query":"tabs","worktreeID":"/tmp/repo"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, let params, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "tabs")
    #expect(params["worktreeID"] == "/tmp/repo")
  }

  @Test func queryTakesPrecedenceOverDeeplink() {
    let json = #"{"query":"repos","deeplink":"supacode://worktree/test"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, _, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "repos")
  }

  @Test func rejectsJSONWithNeitherQueryNorDeeplink() {
    let json = #"{"foo":"bar"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  // MARK: - readPayload.

  @Test func readPayloadReturnsNilOnReadError() {
    let payload = AgentHookSocketServer.readPayload(from: -1) { _, _ in
      errno = EIO
      return -1
    }
    #expect(payload == nil)
  }

  // MARK: - AgentHookEvent decoding.

  // `AgentHookEvent` is the in-app event type the OSC ingest synthesizes; it is
  // also `Decodable` from this JSON shape for test construction.

  @Test func decodesEventWithRequiredFieldsOnly() throws {
    let surfaceID = UUID()
    let json = """
      {
        "event": "session_start",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.event == "session_start")
    #expect(event.eventName == .sessionStart)
    #expect(event.agent == "claude")
    #expect(event.surfaceID == surfaceID)
    #expect(event.pid == nil)
    #expect(event.data == nil)
  }

  @Test func decodesEventWithPidTimestampAndOpaqueData() throws {
    let surfaceID = UUID()
    let json = """
      {
        "event": "notification",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)",
        "pid": 12345,
        "ts": "2026-05-10T12:00:00Z",
        "data": {"title": "Done", "message": "All good"}
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.pid == 12345)
    #expect(event.timestamp != nil)

    struct NotificationPayload: Decodable, Equatable {
      let title: String
      let message: String
    }
    #expect(event.decodeData(NotificationPayload.self) == NotificationPayload(title: "Done", message: "All good"))
  }

  @Test func unknownEventNameKeepsRawStringButHasNilEventName() throws {
    let surfaceID = UUID()
    let json = """
      {
        "event": "future_event_we_dont_know_yet",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.event == "future_event_we_dont_know_yet")
    #expect(event.eventName == nil)
  }

  @Test func eventMissingSurfaceIDFailsToDecode() {
    let json = #"{"event":"session_start","agent":"claude"}"#
    #expect((try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))) == nil)
  }

  @Test func eventWithMalformedSurfaceUUIDFailsToDecode() {
    let json = #"{"event":"session_start","agent":"claude","surface_id":"not-a-uuid"}"#
    #expect((try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))) == nil)
  }

  @Test func eventRejectsNonPositivePid() {
    // `kill(0, 0)` succeeds for the caller's process group and `kill(-N, 0)` for
    // group N, so a pid <= 0 would pin a permanent badge in the liveness sweep.
    for badPid in ["0", "-1", "-12345"] {
      let json = """
        {
          "event": "session_start",
          "agent": "claude",
          "surface_id": "\(UUID().uuidString)",
          "pid": \(badPid)
        }
        """
      #expect(
        (try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))) == nil,
        "Expected nil for pid=\(badPid)")
    }
  }

  // MARK: - Accept-loop lifecycle.

  @Test func acceptLoopDispatchesCommandAndWritesResponse() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    #expect(server.socketPath == path)
    let received = LockIsolated<URL?>(nil)
    server.onCommand = { url, clientFD in
      received.setValue(url)
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true)
    }

    let payload = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let response = try #require(await Self.sendAndReceive(path: path, payload: payload))

    #expect(response.contains(#""ok":true"#))
    #expect(received.value?.scheme == "supacode")
    server.shutdown()
  }

  @Test func commandWithoutHandlerGetsNotReadyResponse() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    #expect(server.socketPath == path)

    let payload = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let response = try #require(await Self.sendAndReceive(path: path, payload: payload))

    #expect(response.contains(#""ok":false"#))
    #expect(response.contains("Not ready."))
    server.shutdown()
  }

  @Test func shutdownRemovesSocketAndRefusesNewConnections() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    #expect(server.socketPath == path)

    server.shutdown()

    #expect(server.socketPath == nil)
    #expect(!FileManager.default.fileExists(atPath: path))
    let response = await Self.sendAndReceive(path: path, payload: "{}")
    #expect(response == nil)
  }

  /// Connects, writes `payload`, half-closes, and reads the response to EOF,
  /// all off the main actor so the server's main-actor dispatch can run while
  /// the client blocks. Returns nil when the connection fails.
  private nonisolated static func sendAndReceive(path: String, payload: String) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientFD >= 0 else {
          continuation.resume(returning: nil)
          return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
          close(clientFD)
          continuation.resume(returning: nil)
          return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
          pathBytes.withUnsafeBufferPointer { buffer in
            memcpy(sunPath, buffer.baseAddress!, buffer.count)
          }
        }
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(clientFD, sockaddrPointer, addrLen)
          }
        }
        guard connected == 0 else {
          close(clientFD)
          continuation.resume(returning: nil)
          return
        }
        let bytes = Array(payload.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer in
          write(clientFD, buffer.baseAddress, buffer.count)
        }
        // Half-close so the server's read-to-EOF loop completes while the
        // response can still come back.
        Darwin.shutdown(clientFD, SHUT_WR)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = chunk.withUnsafeMutableBufferPointer { buffer in
            read(clientFD, buffer.baseAddress, buffer.count)
          }
          guard count > 0 else { break }
          data.append(contentsOf: chunk.prefix(count))
        }
        close(clientFD)
        continuation.resume(returning: String(data: data, encoding: .utf8))
      }
    }
  }
}
