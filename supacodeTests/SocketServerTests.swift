import Darwin
import Foundation
import Testing

@testable import supacode

@MainActor
struct SocketServerTests {
  @Test func systemPingRoundTripOverUnixSocket() throws {
    let socketPath = makeSocketPath()
    let server = SocketServer(path: socketPath) { request in
      if request.parsedMethod == .systemPing {
        return .success(id: request.id, result: .object(["pong": .bool(true)]))
      }
      return .failure(id: request.id, code: .methodNotFound, message: "Unknown")
    }
    try server.start()
    defer { server.stop() }

    let clientFD = try connect(to: socketPath)
    defer { _ = Darwin.close(clientFD) }

    try writeLine("{\"id\":\"1\",\"method\":\"system.ping\"}", to: clientFD)
    let responseLine = try readLine(from: clientFD)
    let response = try decodeResponse(from: responseLine)

    #expect(response.id == "1")
    #expect(response.isSuccess == true)
    #expect(response.result == .object(["pong": .bool(true)]))
  }

  @Test func malformedJsonReturnsInvalidRequest() throws {
    let socketPath = makeSocketPath()
    let server = SocketServer(path: socketPath) { request in
      .failure(id: request.id, code: .methodNotFound, message: "Unknown")
    }
    try server.start()
    defer { server.stop() }

    let clientFD = try connect(to: socketPath)
    defer { _ = Darwin.close(clientFD) }

    try writeLine("{invalid-json", to: clientFD)
    let responseLine = try readLine(from: clientFD)
    let response = try decodeResponse(from: responseLine)

    #expect(response.isSuccess == false)
    #expect(response.error?.code == SocketErrorCode.invalidRequest.rawValue)
  }

  @Test func oversizedRequestLineReturnsInvalidRequest() throws {
    let socketPath = makeSocketPath()
    let server = SocketServer(
      path: socketPath,
      maxRequestLineBytes: 32,
      maxPendingBufferBytes: 64
    ) { request in
      .success(id: request.id, result: .object(["ok": .bool(true)]))
    }
    try server.start()
    defer { server.stop() }

    let clientFD = try connect(to: socketPath)
    defer { _ = Darwin.close(clientFD) }

    try writeLine(
      "{\"id\":\"1\",\"method\":\"system.ping\",\"padding\":\"abcdefghijklmnopqrstuvwxyz\"}",
      to: clientFD
    )
    let responseLine = try readLine(from: clientFD)
    let response = try decodeResponse(from: responseLine)

    #expect(response.isSuccess == false)
    #expect(response.error?.code == SocketErrorCode.invalidRequest.rawValue)
  }

  @Test func stopClosesConnectionsAndRemovesSocketFile() throws {
    let socketPath = makeSocketPath()
    let server = SocketServer(path: socketPath) { request in
      .success(id: request.id, result: .object(["method": .string(request.method)]))
    }
    try server.start()

    let clientFD = try connect(to: socketPath)
    #expect(FileManager.default.fileExists(atPath: socketPath) == true)

    try writeLine("{\"id\":\"1\",\"method\":\"system.ping\"}", to: clientFD)
    _ = try readLine(from: clientFD)

    server.stop()

    #expect(FileManager.default.fileExists(atPath: socketPath) == false)
    do {
      _ = try connect(to: socketPath)
      Issue.record("Expected connect to fail after server stop")
    } catch {
    }

    var byte: UInt8 = 0
    let readResult = Darwin.read(clientFD, &byte, 1)
    #expect(readResult == 0 || (readResult < 0 && errno != EAGAIN))

    _ = Darwin.close(clientFD)
  }

  private func makeSocketPath() -> String {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".supacode-test-sockets", isDirectory: true)
      .appendingPathComponent("sock-\(UUID().uuidString.prefix(12)).sock")
      .path(percentEncoded: false)
  }

  private func decodeResponse(from line: String) throws -> SocketResponse {
    try JSONDecoder().decode(SocketResponse.self, from: Data(line.utf8))
  }

  private func connect(to path: String) throws -> Int32 {
    let clientFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard clientFD >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }

    var one: Int32 = 1
    let oneSize = socklen_t(MemoryLayout<Int32>.size)
    _ = withUnsafePointer(to: &one) { pointer in
      Darwin.setsockopt(
        clientFD,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        pointer,
        oneSize
      )
    }

    var receiveTimeout = timeval(tv_sec: 1, tv_usec: 0)
    let receiveTimeoutSize = socklen_t(MemoryLayout<timeval>.size)
    _ = withUnsafePointer(to: &receiveTimeout) { pointer in
      Darwin.setsockopt(
        clientFD,
        SOL_SOCKET,
        SO_RCVTIMEO,
        pointer,
        receiveTimeoutSize
      )
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString.map { UInt8(bitPattern: $0) })
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      _ = Darwin.close(clientFD)
      throw POSIXError(.ENAMETOOLONG)
    }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      _ = buffer.initializeMemory(as: UInt8.self, repeating: 0)
      buffer.copyBytes(from: pathBytes)
    }

    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
        Darwin.connect(clientFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    if connectResult != 0 {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
      _ = Darwin.close(clientFD)
      throw error
    }

    return clientFD
  }

  private func writeLine(_ line: String, to fileDescriptor: Int32) throws {
    var data = Data(line.utf8)
    data.append(0x0A)
    try writeAll(data, to: fileDescriptor)
  }

  private func readLine(from fileDescriptor: Int32) throws -> String {
    var data = Data()
    var byte: UInt8 = 0

    while true {
      let readCount = Darwin.read(fileDescriptor, &byte, 1)
      if readCount == 0 {
        break
      }
      if readCount < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
      }
      if byte == 0x0A {
        break
      }
      data.append(byte)
    }

    guard let string = String(data: data, encoding: .utf8) else {
      throw POSIXError(.EINVAL)
    }
    return string
  }

  private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
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
