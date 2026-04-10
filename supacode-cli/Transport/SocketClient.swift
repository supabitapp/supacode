import Darwin
import Foundation

/// Low-level Unix domain socket client using POSIX APIs.
nonisolated enum SocketClient {
  enum Error: Swift.Error, LocalizedError {
    case connectionFailed(path: String, errno: Int32)
    case socketConfigFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case responseError(String)

    var errorDescription: String? {
      switch self {
      case .connectionFailed(let path, let code):
        "Failed to connect to socket at \(path): \(String(cString: strerror(code)))"
      case .socketConfigFailed(let code):
        "Failed to configure socket: \(String(cString: strerror(code)))"
      case .writeFailed(let code):
        "Failed to write to socket: \(String(cString: strerror(code)))"
      case .readFailed(let code):
        "Failed to read from socket: \(String(cString: strerror(code)))"
      case .responseError(let message):
        message
      }
    }
  }

  /// Connects, sends data, reads response, parses ok/error. Throws on failure.
  static func sendAndReceive(to path: String, data: Data) throws {
    let response = try sendAndReceiveData(to: path, data: data)
    guard !response.isEmpty else {
      throw Error.responseError("Empty response from Supacode.")
    }
    guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
      let succeeded = json["ok"] as? Bool
    else {
      throw Error.responseError("Malformed response from Supacode.")
    }
    guard succeeded else {
      throw Error.responseError(json["error"] as? String ?? "Command failed.")
    }
  }

  /// Connects, sends data, returns the raw response bytes.
  static func sendAndReceiveData(to path: String, data: Data) throws -> Data {
    try withConnection(to: path, sending: data) { socketFD in
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      guard setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
      else {
        throw Error.socketConfigFailed(errno: errno)
      }

      var responseData = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let bytesRead = buffer.withUnsafeMutableBufferPointer { buf in
          guard let base = buf.baseAddress else { return 0 }
          return Darwin.read(socketFD, base, buf.count)
        }
        if bytesRead == 0 { break }
        if bytesRead < 0 {
          let err = errno
          guard err != EAGAIN, err != EWOULDBLOCK else {
            throw Error.responseError("Timed out waiting for response from Supacode.")
          }
          guard err == EINTR else {
            throw Error.readFailed(errno: err)
          }
          continue
        }
        responseData.append(contentsOf: buffer.prefix(bytesRead))
      }
      return responseData
    }
  }

  /// Creates a socket, connects, writes data, shuts down the write side, runs body, then closes.
  private static func withConnection<T>(
    to path: String,
    sending data: Data,
    body: (Int32) throws -> T
  ) throws -> T {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      throw Error.connectionFailed(path: path, errno: errno)
    }
    defer { close(socketFD) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw Error.connectionFailed(path: path, errno: ENAMETOOLONG)
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }

    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(socketFD, sockaddrPtr, addrLen)
      }
    }
    guard connectResult == 0 else {
      throw Error.connectionFailed(path: path, errno: errno)
    }

    try writeAll(fileDescriptor: socketFD, data: data)
    shutdown(socketFD, SHUT_WR)

    return try body(socketFD)
  }

  private static func writeAll(fileDescriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var totalWritten = 0
      while totalWritten < data.count {
        let written = write(fileDescriptor, baseAddress.advanced(by: totalWritten), data.count - totalWritten)
        if written < 0 {
          guard errno != EINTR else { continue }
          throw Error.writeFailed(errno: errno)
        }
        guard written > 0 else { throw Error.writeFailed(errno: errno) }
        totalWritten += written
      }
    }
  }
}
