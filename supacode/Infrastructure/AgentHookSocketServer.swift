import Darwin
import Foundation

private nonisolated let socketLogger = SupaLogger("AgentHookSocket")

/// Lightweight Unix domain socket server that receives agent hook
/// messages from `nc -U`.
///
/// Two message formats are supported:
/// - **Busy flag**: `<worktreeID> <tabID> <surfaceID> <0|1>\n`
/// - **Notification**: `<worktreeID> <tabID> <surfaceID> <agent>\n<JSON payload>\n`
@MainActor
final class AgentHookSocketServer {
  private(set) var socketPath: String?

  private var listenTask: Task<Void, Never>?
  /// (worktreeID, tabID, surfaceID, active).
  var onBusy: ((String, UUID, UUID, Bool) -> Void)?
  /// (worktreeID, tabID, surfaceID, notification).
  var onNotification: ((String, UUID, UUID, AgentHookNotification) -> Void)?

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
          }
        }
      }
    }
    return true
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

    guard let data = readPayload(from: clientFD) else {
      close(clientFD)
      return nil
    }
    close(clientFD)
    return parse(data: data)
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
