import Foundation

/// Sends a named command with string parameters to the running Supacode app via socket.
nonisolated enum CommandDispatcher {
  static func dispatch(command: String, params: [String: String] = [:]) throws {
    let socketPath = try Dispatcher.resolveSocket()
    var json: [String: Any] = ["command": command]
    for (key, value) in params {
      json[key] = value
    }
    let data = try JSONSerialization.data(withJSONObject: json)
    try SocketClient.sendAndReceive(to: socketPath, data: data)
  }
}
