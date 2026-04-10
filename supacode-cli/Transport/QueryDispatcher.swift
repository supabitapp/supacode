import Foundation

/// Sends a query to the running Supacode app via socket, parses the response, and returns the data array.
nonisolated enum QueryDispatcher {
  static func query(resource: String, params: [String: String] = [:]) throws -> [[String: String]] {
    let socketPath = try Dispatcher.resolveSocket()
    var json: [String: Any] = ["query": resource]
    for (key, value) in params { json[key] = value }
    let data = try JSONSerialization.data(withJSONObject: json)
    let response = try SocketClient.sendAndReceiveData(to: socketPath, data: data)
    guard !response.isEmpty else {
      throw SocketClient.Error.responseError("Empty response from Supacode.")
    }
    guard let parsed = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
      throw SocketClient.Error.responseError("Malformed response from Supacode.")
    }
    guard let succeeded = parsed["ok"] as? Bool, succeeded else {
      let errorMsg = parsed["error"] as? String
      throw SocketClient.Error.responseError(errorMsg ?? "Query failed.")
    }
    guard let items = parsed["data"] as? [[String: String]] else {
      throw SocketClient.Error.responseError("Unexpected data format in query response.")
    }
    return items
  }
}
