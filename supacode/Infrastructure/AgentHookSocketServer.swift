import Darwin
import Foundation
import SupacodeSettingsShared

private nonisolated let socketLogger = SupaLogger("AgentHookSocket")

/// Lightweight Unix domain socket server for the Supacode CLI control protocol.
///
/// Two message formats are supported, both JSON objects:
/// - **Command**: a `"deeplink"` key wrapping a `supacode://` URL.
/// - **Query**: a `"query"` key and optional parameters.
///
/// Agent presence and notifications no longer travel over the socket. Hooks emit
/// them as OSC 3008 to the terminal (see `AgentPresenceOSC`), which also works
/// over SSH where this socket can't be reached; the socket carries only the CLI
/// control protocol.
@MainActor
final class AgentHookSocketServer {
  private(set) var socketPath: String?

  private var listenTask: Task<Void, Never>?
  /// Deeplink URL received from the CLI. Second parameter is the client FD for response.
  var onCommand: ((URL, Int32) -> Void)?
  /// Query received from the CLI. Parameters: resource name, extra params, client FD for response.
  var onQuery: ((String, [String: String], Int32) -> Void)?

  init() {
    let uid = getuid()
    let pid = ProcessInfo.processInfo.processIdentifier
    let directory = "/tmp/supacode-\(uid)"
    let path = "\(directory)/pid-\(pid)"

    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      socketLogger.warning("Failed to create socket directory: \(error)")
      return
    }

    Self.pruneStaleSocketFiles(in: directory)
    unlink(path)
    guard startListening(path: path) else { return }
    socketPath = path
  }

  /// Removes socket files left behind by processes that are no longer running.
  private nonisolated static func pruneStaleSocketFiles(in directory: String) {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
    else { return }
    for entry in entries {
      guard entry.hasPrefix("pid-"),
        let pid = Int32(entry.dropFirst(4))
      else { continue }
      // kill(pid, 0) returns 0 if the process exists.
      guard kill(pid, 0) != 0 else { continue }
      let stalePath = "\(directory)/\(entry)"
      unlink(stalePath)
      socketLogger.info("Pruned stale socket: \(entry)")
    }
  }

  deinit {
    listenTask?.cancel()
    if let socketPath {
      unlink(socketPath)
    }
  }

  func shutdown() {
    listenTask?.cancel()
    listenTask = nil
    if let socketPath {
      unlink(socketPath)
    }
    socketPath = nil
  }

  // MARK: - Socket lifecycle.

  @discardableResult
  private func startListening(path: String) -> Bool {
    let socketFD = Self.createSocket(path: path)
    guard socketFD >= 0 else { return false }

    listenTask = Task.detached { [weak self] in
      socketLogger.info("Listening on \(path)")
      defer { close(socketFD) }

      while !Task.isCancelled {
        var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 200)
        if ready < 0 {
          guard errno == EINTR else {
            socketLogger.warning("poll() failed: \(String(cString: strerror(errno)))")
            break
          }
          continue
        }
        guard ready > 0 else { continue }

        guard let message = Self.acceptAndParse(socketFD: socketFD) else {
          continue
        }

        await MainActor.run { [weak self] in
          switch message {
          case .command(let deeplinkURL, let clientFD):
            guard let self, let handler = self.onCommand else {
              Self.sendCommandResponse(clientFD: clientFD, ok: false, error: "Not ready.")
              return
            }
            handler(deeplinkURL, clientFD)
          case .query(let resource, let params, let clientFD):
            guard let self, let handler = self.onQuery else {
              Self.sendCommandResponse(clientFD: clientFD, ok: false, error: "Not ready.")
              return
            }
            handler(resource, params, clientFD)
          }
        }
      }
    }
    return true
  }

  /// Writes all bytes to an FD, handling partial writes. Logs and
  /// returns silently on write failure.
  private nonisolated static func writeAll(to fileDescriptor: Int32, data: Data) {
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var totalWritten = 0
      while totalWritten < data.count {
        let written = write(
          fileDescriptor, base.advanced(by: totalWritten), data.count - totalWritten)
        if written < 0 {
          guard errno == EINTR else {
            socketLogger.warning("write() failed: \(String(cString: strerror(errno)))")
            return
          }
          continue
        }
        guard written > 0 else { return }
        totalWritten += written
      }
    }
  }

  // MARK: - Socket creation (nonisolated).

  private nonisolated static func createSocket(path: String) -> Int32 {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      socketLogger.warning("socket() failed: \(String(cString: strerror(errno)))")
      return -1
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      socketLogger.warning("Socket path too long: \(path)")
      close(socketFD)
      return -1
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }

    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(socketFD, sockaddrPtr, addrLen)
      }
    }
    guard bindResult == 0 else {
      socketLogger.warning("bind() failed: \(String(cString: strerror(errno)))")
      close(socketFD)
      return -1
    }

    guard listen(socketFD, 8) == 0 else {
      socketLogger.warning("listen() failed: \(String(cString: strerror(errno)))")
      close(socketFD)
      return -1
    }

    return socketFD
  }

  // MARK: - Connection handling (nonisolated).

  /// Maximum payload size (64 KB) to prevent unbounded memory growth.
  private nonisolated static let maxPayloadSize = 65_536

  nonisolated enum Message: Sendable {
    /// CLI command with the client FD kept open for writing a response.
    case command(deeplinkURL: URL, clientFD: Int32)
    /// CLI query with the client FD kept open for writing data back.
    case query(resource: String, params: [String: String], clientFD: Int32)
  }

  /// Writes a JSON response with data to a client and closes the FD.
  nonisolated static func sendQueryResponse(clientFD: Int32, data: [[String: String]]) {
    let json: [String: Any] = ["ok": true, "data": data]
    guard let encoded = try? JSONSerialization.data(withJSONObject: json) else {
      socketLogger.warning("Failed to encode query response")
      writeAll(
        to: clientFD, data: Data("{\"ok\":false,\"error\":\"Internal encoding error.\"}".utf8))
      close(clientFD)
      return
    }
    writeAll(to: clientFD, data: encoded)
    close(clientFD)
  }

  /// Writes a JSON response to a command client and closes the FD.
  nonisolated static func sendCommandResponse(
    clientFD: Int32, ok succeeded: Bool, error: String? = nil
  ) {
    var json: [String: Any] = ["ok": succeeded]
    if let error { json["error"] = error }
    guard let data = try? JSONSerialization.data(withJSONObject: json) else {
      socketLogger.warning("Failed to encode command response")
      writeAll(
        to: clientFD, data: Data("{\"ok\":false,\"error\":\"Internal encoding error.\"}".utf8))
      close(clientFD)
      return
    }
    writeAll(to: clientFD, data: data)
    close(clientFD)
  }

  private nonisolated static func acceptAndParse(
    socketFD: Int32
  ) -> Message? {
    let clientFD = accept(socketFD, nil, nil)
    guard clientFD >= 0 else {
      let err = errno
      if err != EAGAIN, err != EWOULDBLOCK {
        socketLogger.warning("accept() failed: \(String(cString: strerror(err)))")
      }
      return nil
    }

    // Set a read timeout so a misbehaving client cannot block the accept loop.
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    guard
      setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        == 0
    else {
      socketLogger.warning("setsockopt(SO_RCVTIMEO) failed: \(String(cString: strerror(errno)))")
      close(clientFD)
      return nil
    }

    guard let data = readPayload(from: clientFD) else {
      close(clientFD)
      return nil
    }

    guard let message = parse(data: data) else {
      // If the payload looks like a JSON CLI message, send an error
      // response so the CLI does not hang waiting for a reply.
      if data.first == UInt8(ascii: "{") {
        sendCommandResponse(clientFD: clientFD, ok: false, error: "Malformed request.")
      } else {
        close(clientFD)
      }
      return nil
    }

    // Command/query messages keep the FD open so the handler can write a response.
    switch message {
    case .command(let url, _):
      return .command(deeplinkURL: url, clientFD: clientFD)
    case .query(let resource, let params, _):
      return .query(resource: resource, params: params, clientFD: clientFD)
    }
  }

  nonisolated static func readPayload(
    from clientFD: Int32,
    readChunk: (Int32, UnsafeMutableBufferPointer<UInt8>) -> Int = { fileDescriptor, buffer in
      guard let baseAddress = buffer.baseAddress else { return 0 }
      return Darwin.read(fileDescriptor, baseAddress, buffer.count)
    }
  ) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let bytesRead = buffer.withUnsafeMutableBufferPointer { buffer in
        readChunk(clientFD, buffer)
      }
      if bytesRead < 0 {
        let err = errno
        socketLogger.warning("read() failed (\(err)): \(String(cString: strerror(err)))")
        return nil
      }
      if bytesRead == 0 { return data }
      data.append(contentsOf: buffer.prefix(bytesRead))
      if data.count > maxPayloadSize {
        socketLogger.warning("Payload exceeded \(maxPayloadSize) bytes, dropping connection")
        return nil
      }
    }
  }

  nonisolated static func parse(data: Data) -> Message? {
    guard let rawString = String(data: data, encoding: .utf8) else {
      socketLogger.warning("Dropped non-UTF8 CLI payload (\(data.count) bytes)")
      return nil
    }
    let raw = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
      socketLogger.debug("Dropped empty CLI payload")
      return nil
    }
    // The CLI control protocol is always a JSON object (command or query).
    guard raw.hasPrefix("{") else {
      socketLogger.debug("Dropped non-JSON socket payload")
      return nil
    }
    return parseJSONMessage(data: data)
  }

  /// Parses an agent notification JSON payload into an `AgentHookNotification`,
  /// decoding the body from whichever agent-specific field is present. The OSC
  /// notify leg is the sole caller; the socket no longer carries notifications.
  nonisolated static func parseNotification(
    agent: String,
    data: Data
  ) -> AgentHookNotification? {
    guard let payload = try? JSONDecoder().decode(AgentHookPayload.self, from: data) else {
      let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-UTF8>"
      socketLogger.warning("Failed to decode \(agent) notification payload: \(preview)")
      return nil
    }

    if payload.body == nil {
      socketLogger.warning(
        "All body fields nil in \(agent) \(payload.hookEventName ?? "unknown") notification")
    }
    return AgentHookNotification(
      agent: agent,
      event: payload.hookEventName ?? "unknown",
      title: payload.title,
      body: payload.body
    )
  }

  /// Parses a CLI JSON message into a query or command. The placeholder
  /// `clientFD` of `-1` is replaced with the real FD in `acceptAndParse`.
  private nonisolated static func parseJSONMessage(data: Data) -> Message? {
    guard let request = SocketCommandRequest(data: data) else {
      socketLogger.warning("Failed to decode CLI message payload")
      return nil
    }
    switch request {
    case .query(let resource, let params):
      return .query(resource: resource, params: params, clientFD: -1)
    case .command(let deeplink, _):
      guard let url = URL(string: deeplink), url.scheme == "supacode" else {
        socketLogger.warning("Invalid CLI deeplink URL: \(deeplink)")
        return nil
      }
      return .command(deeplinkURL: url, clientFD: -1)
    }
  }
}

/// Parsed notification from a coding agent hook event.
nonisolated struct AgentHookNotification: Equatable, Sendable {
  let agent: String
  let event: String
  let title: String?
  let body: String?
}

/// An agent presence/activity event. Built by the OSC ingest from a verified
/// presence signal (memberwise init, attributed to the receiving surface), and
/// also `Decodable` from the legacy JSON envelope shape below for test
/// construction. `surface_id` is the only scope field; tab and worktree are
/// derived app-side from the current terminal topology so a moved/split surface
/// never carries stale attribution.
///
/// JSON shape (the Decodable contract):
/// ```json
/// {
///   "event": "session_start",   // discriminator + event name (required)
///   "v": 1,                     // protocol version (required)
///   "agent": "claude",          // SkillAgent rawValue (required)
///   "surface_id": "<UUID>",     // required
///   "pid": 12345,               // optional, agent process pid
///   "ts": "<ISO8601>",          // optional, sender clock
///   "data": { ... }             // optional, event-specific
/// }
/// ```
nonisolated struct AgentHookEvent: Equatable, Sendable, Decodable {
  /// Known event names. Stored as raw `String` so an unknown event from a newer
  /// emitter / older app doesn't drop; handlers can ignore them.
  enum EventName: String, Sendable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case busy
    case awaitingInput = "awaiting_input"
    case idle
    case notification
  }

  let version: Int
  let agent: String
  let event: String
  let surfaceID: UUID
  let pid: pid_t?
  let timestamp: Date?
  /// Event-specific payload preserved as opaque JSON. Handlers decode with
  /// their own typed shape via `decodeData(_:)`, keeping this layer decoupled
  /// from per-event payload schemas.
  let data: JSONValue?

  /// Convenience: the event name as a known case, or nil for an unrecognized event.
  var eventName: EventName? { EventName(rawValue: event) }

  /// Decode the per-event `data` payload into a concrete type. Returns nil
  /// when `data` is missing. Returns nil and logs a warning when `data` is
  /// present but fails to decode against `T`; silent nil there would make a
  /// shape mismatch invisible to handlers.
  func decodeData<T: Decodable>(_ type: T.Type = T.self) -> T? {
    guard let data else { return nil }
    do {
      let bytes = try JSONEncoder().encode(data)
      return try JSONDecoder().decode(type, from: bytes)
    } catch {
      socketLogger.warning("Failed to decode \(event) data as \(type): \(error)")
      return nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case event, agent, pid, data
    case version = "v"
    case surfaceID = "surface_id"
    case timestamp = "ts"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let event = try container.decode(String.self, forKey: .event)
    guard !event.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .event, in: container, debugDescription: "`event` must be non-empty.")
    }
    self.event = event
    self.surfaceID = try Self.decodeUUID(from: container, forKey: .surfaceID)
    self.agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? "unknown"
    self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    if let rawPid = try container.decodeIfPresent(Int.self, forKey: .pid) {
      // Reject 0 and negatives: `kill(0, 0)` succeeds for the caller's
      // process group and `kill(-N, 0)` for group N, both of which would
      // pin a permanent badge in the liveness sweep on a buggy hook (e.g.
      // `pid:$$` from a subshell that recycled).
      guard let bounded = pid_t(exactly: rawPid), bounded > 0 else {
        throw DecodingError.dataCorruptedError(
          forKey: .pid, in: container,
          debugDescription: "`pid` \(rawPid) is not a positive pid_t value.")
      }
      self.pid = bounded
    } else {
      self.pid = nil
    }
    if let rawTimestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) {
      self.timestamp = try? Date(rawTimestamp, strategy: .iso8601)
    } else {
      self.timestamp = nil
    }
    self.data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
  }

  /// Memberwise init for synthesizing events from sources other than the JSON
  /// wire. The OSC presence path uses it: attribution is by the receiving
  /// surface and there is no remote pid, so `pid` defaults to nil.
  init(
    version: Int = 1,
    agent: String,
    event: String,
    surfaceID: UUID,
    pid: pid_t? = nil,
    timestamp: Date? = nil,
    data: JSONValue? = nil
  ) {
    self.version = version
    self.agent = agent
    self.event = event
    self.surfaceID = surfaceID
    // Mirror the Decodable validation: a non-positive pid would let `kill(0/-N, 0)`
    // match the caller's process group and pin a permanent badge.
    if let pid, pid <= 0 {
      socketLogger.warning("Clamped non-positive pid \(pid) to nil in AgentHookEvent(agent: \(agent)).")
      self.pid = nil
    } else {
      self.pid = pid
    }
    self.timestamp = timestamp
    self.data = data
  }

  private static func decodeUUID(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> UUID {
    let raw = try container.decode(String.self, forKey: key)
    guard let uuid = UUID(uuidString: raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: container,
        debugDescription: "`\(key.stringValue)` is not a valid UUID: \(raw).")
    }
    return uuid
  }
}

/// Raw JSON payload from a coding agent hook event. The `body` is decoded from
/// whichever agent-specific field is present: Claude uses `message`, Codex uses
/// `last_assistant_message`, Kiro uses `assistant_response`. Precedence favors
/// `message` so unknown agents that speak the Claude shape keep working.
private nonisolated struct AgentHookPayload: Decodable {
  let hookEventName: String?
  let title: String?
  let body: String?

  private enum CodingKeys: String, CodingKey {
    case hookEventName = "hook_event_name"
    case title
    case message
    case lastAssistantMessage = "last_assistant_message"
    case assistantResponse = "assistant_response"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    // Tolerate per-field decode errors (e.g. `"message": 42`) so a single
    // malformed field does not drop the whole notification; fall through
    // to the next candidate instead.
    let candidates = [CodingKeys.message, .lastAssistantMessage, .assistantResponse]
      .map { key in Self.decodeOptionalString(container, forKey: key) }
    // Skip empty strings too: Claude occasionally emits `"message": ""`, in
    // which case Codex's `last_assistant_message` / Kiro's `assistant_response`
    // still hold the useful body.
    body = candidates.compactMap { $0 }.first { !$0.isEmpty }
  }

  private static func decodeOptionalString(
    _ container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) -> String? {
    do {
      return try container.decodeIfPresent(String.self, forKey: key)
    } catch {
      socketLogger.warning("Failed to decode hook payload field \(key.rawValue): \(error)")
      return nil
    }
  }
}

/// Parsed CLI request payload: either a deeplink command or a query with params.
private nonisolated enum SocketCommandRequest {
  case command(deeplink: String, params: [String: String])
  case query(resource: String, params: [String: String])

  init?(data: Data) {
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    var extracted: [String: String] = [:]
    for (key, value) in dict where key != "deeplink" && key != "query" {
      if let str = value as? String { extracted[key] = str }
    }
    // Query takes precedence when both keys are present.
    if let resource = dict["query"] as? String {
      self = .query(resource: resource, params: extracted)
    } else if let deeplink = dict["deeplink"] as? String {
      self = .command(deeplink: deeplink, params: extracted)
    } else {
      return nil
    }
  }
}
