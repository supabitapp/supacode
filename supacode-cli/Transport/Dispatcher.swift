import Foundation

/// Dispatches a deeplink URL to the running Supacode app via its Unix domain socket.
/// Launches the app and waits for the socket if not already running.
nonisolated enum Dispatcher {
  /// Sends a deeplink URL to the app via socket.
  static func dispatch(deeplinkURL: String) throws {
    let socketPath = try resolveSocket()
    let json: [String: String] = ["deeplink": deeplinkURL]
    let data = try JSONSerialization.data(withJSONObject: json)
    try SocketClient.sendAndReceive(to: socketPath, data: data)
  }

  /// Returns the socket path, launching the app and waiting if needed.
  static func resolveSocket() throws -> String {
    // Inside a Supacode terminal — use the env var if the socket is still alive.
    if let envPath = SocketDiscovery.fromEnvironment(), SocketDiscovery.isAlive(envPath) {
      return envPath
    }

    // Outside the app — look for an existing socket.
    let existing = try SocketDiscovery.listAll()
    if existing.count == 1 {
      return existing[0]
    }
    if existing.count > 1 {
      throw SocketClient.Error.responseError(
        "Multiple Supacode instances found. Run inside a Supacode terminal or specify SUPACODE_SOCKET_PATH.\n"
          + existing.joined(separator: "\n")
      )
    }

    // No socket found — launch the app and wait for it.
    try launchApp()
    guard let path = try waitForSocket(timeout: 10.0) else {
      throw SocketClient.Error.responseError("Timed out waiting for Supacode to start.")
    }
    return path
  }

  private static func launchApp() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Supacode"]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      let detail = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let message = detail.isEmpty ? "Failed to launch Supacode (exit \(process.terminationStatus))." : detail
      throw SocketClient.Error.responseError(message)
    }
  }

  private static func waitForSocket(timeout: TimeInterval) throws -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    FileHandle.standardError.write(Data("Waiting for Supacode to start...\n".utf8))
    var lastError: Swift.Error?
    while Date() < deadline {
      do {
        let sockets = try SocketDiscovery.listAll()
        if let first = sockets.first { return first }
      } catch {
        lastError = error
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    if let lastError { throw lastError }
    return nil
  }
}
