import Foundation
import SupacodeSettingsShared

nonisolated private let scannerLogger = SupaLogger("ZmxOSCScanner")

/// A complete OSC sequence lifted off a dormant session's broadcast stream.
/// `code` is the identifier the sink consumes (9 notification, 3008 agent
/// events, 0/2 title; other codes drop). `payload` is the bytes after the `;`.
nonisolated struct ZmxOSCSequence: Equatable, Sendable {
  let code: Int
  let payload: [UInt8]

  var payloadString: String? { String(bytes: payload, encoding: .utf8) }
}

/// Incremental extractor for OSC sequences (`ESC ] <code> [; data] <terminator>`,
/// terminator BEL `0x07` or ST `ESC \`) in a raw terminal byte stream. Fed
/// arbitrary chunks, so parse state persists across `scan(_:)` calls; a sequence
/// may split across reads. Non-OSC bytes are discarded.
nonisolated struct ZmxOSCScanner {
  /// Hard cap on one sequence's accumulated bytes. Past this the scanner reads
  /// on to the terminator but drops the sequence, so a runaway never swallows
  /// the next one.
  static let maxSequenceLength = 8192

  private enum State {
    /// Outside any sequence, waiting for `ESC`.
    case ground
    /// Saw `ESC` in ground, expecting `]` to open an OSC.
    case escape
    /// Inside an OSC, accumulating payload bytes.
    case osc
    /// Saw `ESC` inside an OSC, expecting `\` to close it (ST).
    case oscEscape
  }

  private var state: State = .ground
  private var buffer: [UInt8] = []
  private var overflowed = false

  mutating func scan(_ bytes: [UInt8]) -> [ZmxOSCSequence] {
    var out: [ZmxOSCSequence] = []
    for byte in bytes {
      switch state {
      case .ground:
        if byte == 0x1B { state = .escape }
      case .escape:
        if byte == 0x5D {
          openSequence()
        } else if byte != 0x1B {
          // Not `]` and not a fresh `ESC`: abandon and return to ground.
          state = .ground
        }
      case .osc:
        if byte == 0x07 {
          finish(into: &out)
        } else if byte == 0x1B {
          state = .oscEscape
        } else {
          append(byte)
        }
      case .oscEscape:
        if byte == 0x5C {
          finish(into: &out)
        } else {
          // Malformed ST: abandon the in-progress sequence and reprocess this
          // byte from ground so a fresh `ESC` still opens the next sequence.
          reset()
          if byte == 0x1B { state = .escape }
        }
      }
    }
    return out
  }

  private mutating func openSequence() {
    state = .osc
    buffer.removeAll(keepingCapacity: true)
    overflowed = false
  }

  private mutating func append(_ byte: UInt8) {
    guard buffer.count < Self.maxSequenceLength else {
      overflowed = true
      return
    }
    buffer.append(byte)
  }

  private mutating func finish(into out: inout [ZmxOSCSequence]) {
    defer { reset() }
    guard !overflowed else {
      let code = Self.parse(buffer)?.code
      scannerLogger.debug(
        "Discarding overflowed OSC (code \(code.map(String.init) ?? "?"), capped at \(buffer.count) bytes)")
      return
    }
    guard let sequence = Self.parse(buffer) else { return }
    out.append(sequence)
  }

  private mutating func reset() {
    state = .ground
    buffer.removeAll(keepingCapacity: true)
    overflowed = false
  }

  /// Splits `<code>[;data]` into a numeric code and the trailing payload.
  private static func parse(_ bytes: [UInt8]) -> ZmxOSCSequence? {
    guard !bytes.isEmpty else { return nil }
    if let separator = bytes.firstIndex(of: 0x3B) {
      guard let code = parseCode(bytes[..<separator]) else { return nil }
      return ZmxOSCSequence(code: code, payload: Array(bytes[bytes.index(after: separator)...]))
    }
    guard let code = parseCode(bytes[...]) else { return nil }
    return ZmxOSCSequence(code: code, payload: [])
  }

  /// Parses an all-digit code slice; nil for empty or non-numeric input. Capped
  /// at six digits since every OSC code the app cares about is <= 3008.
  private static func parseCode(_ bytes: ArraySlice<UInt8>) -> Int? {
    guard !bytes.isEmpty, bytes.count <= 6 else { return nil }
    var value = 0
    for byte in bytes {
      guard byte >= 0x30, byte <= 0x39 else { return nil }
      value = value * 10 + Int(byte - 0x30)
    }
    return value
  }
}
