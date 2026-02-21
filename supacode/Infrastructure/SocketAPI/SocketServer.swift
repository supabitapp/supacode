import Darwin
import Foundation

@MainActor
final class SocketServer {
  private let path: String
  private let onRequest: @Sendable (SocketRequest) async -> SocketResponse

  private var listenFD: Int32 = -1
  private var acceptTask: Task<Void, Never>?

  init(path: String, onRequest: @escaping @Sendable (SocketRequest) async -> SocketResponse) {
    self.path = path
    self.onRequest = onRequest
  }

  func start() throws {
    guard acceptTask == nil else { return }

    do {
      try Self.ensureSocketDirectory(for: path)
      try Self.unlinkSocket(at: path)

      let listenSocketFD = try Self.createListeningSocket(at: path)
      listenFD = listenSocketFD

      let handler = onRequest
      acceptTask = Task.detached(priority: .background) {
        await Self.acceptLoop(listenFD: listenSocketFD, onRequest: handler)
      }
    } catch {
      cleanupSocket()
      throw error
    }
  }

  func stop() {
    acceptTask?.cancel()
    acceptTask = nil
    cleanupSocket()
  }

  private func cleanupSocket() {
    if listenFD >= 0 {
      _ = Darwin.close(listenFD)
      listenFD = -1
    }
    try? Self.unlinkSocket(at: path)
  }

  private static func ensureSocketDirectory(for path: String) throws {
    let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let directoryPath = directoryURL.path(percentEncoded: false)
    let result = directoryPath.withCString { pointer in
      Darwin.chmod(pointer, mode_t(0o700))
    }
    if result != 0 {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }
  }

  private static func unlinkSocket(at path: String) throws {
    let result = path.withCString { pointer in
      Darwin.unlink(pointer)
    }
    if result == 0 || errno == ENOENT {
      return
    }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
  }

  private static func createListeningSocket(at path: String) throws -> Int32 {
    let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }

    do {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)

      let pathBytes = Array(path.utf8CString.map { UInt8(bitPattern: $0) })
      guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
      }

      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        _ = buffer.initializeMemory(as: UInt8.self, repeating: 0)
        buffer.copyBytes(from: pathBytes)
      }

      let addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
          Darwin.bind(socketFD, rebound, addressSize)
        }
      }
      guard bindResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
      }

      let chmodResult = path.withCString { pointer in
        Darwin.chmod(pointer, mode_t(0o600))
      }
      guard chmodResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
      }

      let listenResult = Darwin.listen(socketFD, 16)
      guard listenResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
      }

      return socketFD
    } catch {
      _ = Darwin.close(socketFD)
      throw error
    }
  }

  private static func acceptLoop(
    listenFD: Int32,
    onRequest: @escaping @Sendable (SocketRequest) async -> SocketResponse
  ) {
    while !Task.isCancelled {
      let connectionFD = Darwin.accept(listenFD, nil, nil)

      if connectionFD < 0 {
        if errno == EINTR {
          continue
        }
        break
      }

      Task.detached(priority: .background) {
        await handleConnection(connectionFD: connectionFD, onRequest: onRequest)
      }
    }
  }

  private static func handleConnection(
    connectionFD: Int32,
    onRequest: @escaping @Sendable (SocketRequest) async -> SocketResponse
  ) async {
    defer {
      _ = Darwin.close(connectionFD)
    }

    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    while !Task.isCancelled {
      let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(connectionFD, rawBuffer.baseAddress, rawBuffer.count)
      }

      if readCount == 0 {
        break
      }

      if readCount < 0 {
        if errno == EINTR {
          continue
        }
        break
      }

      pending.append(buffer, count: readCount)

      while let newlineIndex = pending.firstIndex(of: 0x0A) {
        let line = pending[..<newlineIndex]
        pending.removeSubrange(...newlineIndex)

        if line.isEmpty {
          continue
        }

        let requestData = Data(line)
        let response: SocketResponse

        do {
          let request = try decoder.decode(SocketRequest.self, from: requestData)
          response = await onRequest(request)
        } catch {
          response = .failure(
            id: nil,
            code: .invalidRequest,
            message: "Request must be valid JSON matching the socket request schema"
          )
        }

        do {
          var responseData = try encoder.encode(response)
          responseData.append(0x0A)
          try writeAll(responseData, to: connectionFD)
        } catch {
          return
        }
      }
    }
  }

  private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var totalWritten = 0

      while totalWritten < rawBuffer.count {
        let pointer = baseAddress.advanced(by: totalWritten)
        let writeCount = Darwin.write(fileDescriptor, pointer, rawBuffer.count - totalWritten)

        if writeCount < 0 {
          if errno == EINTR {
            continue
          }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }

        totalWritten += writeCount
      }
    }
  }
}
