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

  // MARK: - Notification payload decoding (OSC notify leg).

  // `parseNotification` is the agent-JSON body decoder the OSC notify
  // leg uses; these lock the per-agent title/body precedence it relies on.

  @Test func decodesNotificationTitleAndMessageBody() {
    let payload = #"{"hook_event_name":"Stop","title":"Done","message":"All tasks complete"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "claude", data: Data(payload.utf8))
    #expect(notification?.agent == "claude")
    #expect(notification?.event == "Stop")
    #expect(notification?.title == "Done")
    #expect(notification?.body == "All tasks complete")
  }

  @Test func fallsBackToLastAssistantMessage() {
    let payload = #"{"hook_event_name":"Stop","last_assistant_message":"fallback body"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "codex", data: Data(payload.utf8))
    #expect(notification?.body == "fallback body")
  }

  @Test func fallsBackToAssistantResponse() {
    let payload = #"{"hook_event_name":"stop","assistant_response":"kiro body"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "kiro", data: Data(payload.utf8))
    #expect(notification?.body == "kiro body")
  }

  @Test func lastAssistantMessageTakesPrecedenceOverAssistantResponse() {
    let payload =
      #"{"hook_event_name":"Stop","last_assistant_message":"codex body","assistant_response":"kiro body"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "codex", data: Data(payload.utf8))
    #expect(notification?.body == "codex body")
  }

  @Test func messageFieldTakesPrecedenceOverAllFallbacks() {
    let payload =
      #"{"hook_event_name":"Stop","message":"primary","#
      + #""last_assistant_message":"secondary","assistant_response":"tertiary"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "claude", data: Data(payload.utf8))
    #expect(notification?.body == "primary")
  }

  @Test func nullMessageFieldFallsThroughToLastAssistantMessage() {
    let payload = #"{"hook_event_name":"Stop","message":null,"last_assistant_message":"fallback"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "codex", data: Data(payload.utf8))
    #expect(notification?.body == "fallback")
  }

  @Test func emptyStringMessageFieldFallsThroughToFallback() {
    let payload = #"{"hook_event_name":"Stop","message":"","last_assistant_message":"real body"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "codex", data: Data(payload.utf8))
    #expect(notification?.body == "real body")
  }

  @Test func typeMismatchOnMessageFieldFallsThroughToFallback() {
    // Claude-shape with an unexpectedly numeric message: the decoder tolerates
    // the mismatch and falls through to assistant_response.
    let payload = #"{"hook_event_name":"stop","message":42,"assistant_response":"kiro body"}"#
    let notification = AgentHookSocketServer.parseNotification(agent: "kiro", data: Data(payload.utf8))
    #expect(notification?.body == "kiro body")
  }

  @Test func invalidJSONNotificationPayloadReturnsNil() {
    let notification = AgentHookSocketServer.parseNotification(
      agent: "claude", data: Data("not json at all".utf8))
    #expect(notification == nil)
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
}
