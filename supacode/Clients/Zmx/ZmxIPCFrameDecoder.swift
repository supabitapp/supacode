import Foundation

/// One framed zmx IPC message off the wire. `tag` is the raw wire value; the
/// consumer maps it (see `ZmxIPCTag`) and ignores anything it does not care
/// about, so an unknown tag is skipped rather than fatal.
nonisolated struct ZmxIPCFrame: Equatable, Sendable {
  let tag: UInt8
  let payload: [UInt8]
}

/// zmx IPC tag values a passive tail client observes (full enum in
/// `ThirdParty/zmx/src/ipc.zig`). A passive client only needs `.output`
/// (broadcast pty chunks); other tags are ignored.
nonisolated enum ZmxIPCTag {
  static let output: UInt8 = 1
}

/// Incremental decoder for zmx's IPC framing: an 8-byte header (byte 0 tag,
/// bytes 1-4 little-endian `u32` len, bytes 5-7 padding) then `len` payload
/// bytes. Chunks split arbitrarily, so unconsumed bytes stay buffered until the
/// next `decode(_:)`.
nonisolated struct ZmxIPCFrameDecoder {
  static let headerSize = 8

  /// Generous headroom over the ~4 KiB pty-chunk norm; a declared length above it
  /// means a desynced or corrupt stream, so decoding throws instead of buffering.
  static let maxPayloadSize = 1 << 20

  enum DecodeError: Error, Equatable {
    case payloadTooLarge(UInt32)
  }

  private var buffer: [UInt8] = []

  mutating func decode(_ bytes: [UInt8]) throws -> [ZmxIPCFrame] {
    buffer.append(contentsOf: bytes)
    var frames: [ZmxIPCFrame] = []
    var offset = 0
    while buffer.count - offset >= Self.headerSize {
      let length = Self.readLength(buffer, at: offset + 1)
      guard length <= Self.maxPayloadSize else {
        throw DecodeError.payloadTooLarge(length)
      }
      let total = Self.headerSize + Int(length)
      guard buffer.count - offset >= total else { break }
      let payloadStart = offset + Self.headerSize
      frames.append(
        ZmxIPCFrame(
          tag: buffer[offset],
          payload: Array(buffer[payloadStart..<(payloadStart + Int(length))])
        )
      )
      offset += total
    }
    if offset > 0 { buffer.removeFirst(offset) }
    return frames
  }

  private static func readLength(_ bytes: [UInt8], at index: Int) -> UInt32 {
    UInt32(bytes[index])
      | UInt32(bytes[index + 1]) << 8
      | UInt32(bytes[index + 2]) << 16
      | UInt32(bytes[index + 3]) << 24
  }
}
