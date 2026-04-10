import Darwin
import Foundation

private nonisolated let socketLogger = SupaLogger("AgentHookSocket")

/// Lightweight Unix domain socket server that receives messages from
/// agent hooks (via `nc -U`) and the Supacode CLI tool.
///
/// Four message formats are supported:
/// - **Busy flag**: `<worktreeID> <tabID> <surfaceID> <0|1>\n`
/// - **Notification**: `<worktreeID> <tabID> <surfaceID> <agent>\n<JSON payload>\n`.
///   The agent field defaults to `"unknown"` when absent.
/// - **Command**: JSON object with a `"deeplink"` key wrapping a `supacode://` URL.
/// - **Query**: JSON object with a `"query"` key and optional parameters.
@MainActor
final class AgentHookSocketServer {
  private(set) var socketPath: String?

  private var listenTask: Task<Void, Never>?
  /// (worktreeID, tabID, surfaceID, active).
  var onBusy: ((String, UUID, UUID, Bool) -> Void)?
  /// (worktreeID, tabID, surfaceID, notification).
  var onNotification: ((String, UUID, UUID, AgentHookNotification) -> Void)?
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
          case .busy(let worktreeID, let tabID, let surfaceID, let active):
            self?.onBusy?(worktreeID, tabID, surfaceID, active)
          case .notification(let worktreeID, let tabID, let surfaceID, let notification):
            self?.onNotification?(worktreeID, tabID, surfaceID, notification)
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
        let written = write(fileDescriptor, base.advanced(by: totalWritten), data.count - totalWritten)
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
    case busy(worktreeID: String, tabID: UUID, surfaceID: UUID, active: Bool)
    case notification(worktreeID: String, tabID: UUID, surfaceID: UUID, notification: AgentHookNotification)
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
      writeAll(to: clientFD, data: Data("{\"ok\":false,\"error\":\"Internal encoding error.\"}".utf8))
      close(clientFD)
      return
    }
    writeAll(to: clientFD, data: encoded)
    close(clientFD)
  }

  /// Writes a JSON response to a command client and closes the FD.
  nonisolated static func sendCommandResponse(clientFD: Int32, ok succeeded: Bool, error: String? = nil) {
    var json: [String: Any] = ["ok": succeeded]
    if let error { json["error"] = error }
    guard let data = try? JSONSerialization.data(withJSONObject: json) else {
      socketLogger.warning("Failed to encode command response")
      writeAll(to: clientFD, data: Data("{\"ok\":false,\"error\":\"Internal encoding error.\"}".utf8))
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
    guard setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
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

    // For command/query messages, keep the FD open for the response.
    switch message {
    case .command(let url, _):
      return .command(deeplinkURL: url, clientFD: clientFD)
    case .query(let resource, let params, _):
      return .query(resource: resource, params: params, clientFD: clientFD)
    default:
      close(clientFD)
      return message
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
      socketLogger.warning("Dropped non-UTF8 hook payload (\(data.count) bytes)")
      return nil
    }

    let raw = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
      socketLogger.debug("Dropped empty hook payload")
      return nil
    }

    // JSON object starting with `{` → CLI message (command or query).
    if raw.hasPrefix("{") {
      return parseCommand(data: data)
    }

    // Format: worktreeID tabID surfaceID <flag|agent>.
    // Single line with 4 fields → busy flag.
    // Multiple lines → notification (4th field is agent, rest is JSON).
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
    let headerParts = lines[0].split(separator: " ", maxSplits: 3)
    guard
      headerParts.count >= 3,
      let tabID = UUID(uuidString: String(headerParts[1])),
      let surfaceID = UUID(uuidString: String(headerParts[2]))
    else {
      socketLogger.warning("Malformed header: \(lines[0])")
      return nil
    }

    let worktreeID = String(headerParts[0])

    if lines.count == 1, headerParts.count == 4 {
      let active = String(headerParts[3]) != "0"
      return .busy(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID, active: active)
    }

    // Multiple lines → notification. Fourth header field is the agent name.
    // Agent is a raw string intentionally — left open for custom agents
    // since the socket is already listening and anyone can send messages.
    let agent = headerParts.count >= 4 ? String(headerParts[3]) : "unknown"
    let jsonPayload = lines.dropFirst().joined(separator: "\n")

    guard let jsonData = jsonPayload.data(using: .utf8) else {
      socketLogger.warning("Invalid notification payload encoding")
      return nil
    }

    guard let notification = parseNotification(agent: agent, data: jsonData) else {
      return nil
    }
    return .notification(
      worktreeID: worktreeID,
      tabID: tabID,
      surfaceID: surfaceID,
      notification: notification
    )
  }

  private nonisolated static func parseNotification(
    agent: String,
    data: Data
  ) -> AgentHookNotification? {
    guard let payload = try? JSONDecoder().decode(AgentHookPayload.self, from: data) else {
      let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-UTF8>"
      socketLogger.warning("Failed to decode \(agent) notification payload: \(preview)")
      return nil
    }

    let body = payload.message ?? payload.lastAssistantMessage
    return AgentHookNotification(
      agent: agent,
      event: payload.hookEventName ?? "unknown",
      title: payload.title,
      body: body
    )
  }

  /// Parses a JSON CLI message into a command or query. The placeholder
  /// `clientFD` of `-1` is replaced with the real FD in `acceptAndParse`.
  private nonisolated static func parseCommand(data: Data) -> Message? {
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

/// Raw JSON payload from a coding agent hook event.
private nonisolated struct AgentHookPayload: Decodable {
  let hookEventName: String?
  let title: String?
  let message: String?
  let lastAssistantMessage: String?

  enum CodingKeys: String, CodingKey {
    case hookEventName = "hook_event_name"
    case title
    case message
    case lastAssistantMessage = "last_assistant_message"
  }
}

/// Parsed CLI request payload: either a deeplink command or a query with params.
private nonisolated enum SocketCommandRequest {
  case command(deeplink: String, params: [String: String])
  case query(resource: String, params: [String: String])

  init?(data: Data) {
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
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
