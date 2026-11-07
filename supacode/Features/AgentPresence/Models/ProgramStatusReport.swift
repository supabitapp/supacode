import Foundation
import SupacodeSettingsShared

/// One OSC 7501 (Program Status Protocol, revision 0.4) report: what a program
/// in the terminal says it is doing. Each report replaces its record whole, so a
/// nil field means the record no longer has that value.
///
/// Live surfaces get reports already parsed by libghostty. Dormant zmx sessions
/// bypass libghostty, so `parse(body:)` applies the same rules to the raw body.
nonisolated struct ProgramStatusReport: Equatable, Sendable {
  enum State: String, Equatable, Sendable, CaseIterable {
    case idle
    case working
    case done
    case blocked
    case error
    /// Not a real state: removes the addressed record and every record beneath it.
    case clear
  }

  /// What a `blocked` program needs from the user.
  enum Kind: String, Equatable, Sendable, CaseIterable {
    case permission
    case question
    case auth
  }

  var state: State
  /// Empty for the root record, the program itself.
  var id: String = ""
  var kind: Kind?
  /// 0 to 100. Nil is indeterminate.
  var progress: Int?
  var app: String?
  var title: String?
  var message: String?

  var isRoot: Bool { id.isEmpty }

  var agent: SkillAgent? { app.flatMap(SkillAgent.init(programStatusApp:)) }
}

// MARK: - Raw body parsing.

nonisolated extension ProgramStatusReport {
  /// Size limits from the specification, in bytes. A report that breaks any of
  /// them is discarded whole. The body limit assumes the longer `ESC \` terminator.
  enum Limits {
    static let maxBodyBytes = 4096 - "\u{1B}]7501;".utf8.count - "\u{1B}\\".utf8.count
    static let maxKeyBytes = 16
    static let maxMessageEncodedBytes = 2732
    static let maxMessageBytes = 2048
    static let maxTitleEncodedBytes = 256
    static let maxTitleBytes = 192
    static let maxAppBytes = 32
    static let maxIDBytes = 128
    static let maxIDSegmentBytes = 32
    static let maxIDDepth = 8
  }

  private static let nameBytes = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-".utf8)
  private static let valueBytes = nameBytes.union(",/=".utf8)
  private static let asciiWhitespace = Set(" \t\n\r\u{0B}\u{0C}".utf8)

  /// Parses the body of `ESC ] 7501 ; <body> ST`. Nil for the `?` support query
  /// and for any report the specification says to discard: a missing or unknown
  /// state, a broken limit, a malformed id, or undecodable title or msg text. A
  /// pair that is malformed or has an unknown key is skipped.
  static func parse(body: String) -> ProgramStatusReport? {
    let bytes = Array(body.utf8)
    guard bytes.count <= Limits.maxBodyBytes, bytes != Array("?".utf8) else { return nil }
    guard let pairs = Pairs(bytes), !pairs.breaksALimit else { return nil }

    var title: String?
    if let encoded = pairs.values["title"]?.last, !encoded.isEmpty {
      guard let text = decodeText(encoded), text.utf8.count <= Limits.maxTitleBytes else { return nil }
      title = text
    }
    var message: String?
    if let encoded = pairs.values["msg"]?.last, !encoded.isEmpty {
      guard let text = decodeText(encoded) else { return nil }
      message = text
    }
    guard let rawState = pairs.values["state"]?.last, let state = State(rawValue: rawState) else { return nil }

    var report = ProgramStatusReport(state: state, id: pairs.values["id"]?.last ?? "")
    report.title = title
    report.message = message
    if let app = pairs.values["app"]?.last, isName(app) { report.app = app }
    if state == .blocked, let kind = pairs.values["kind"]?.last { report.kind = Kind(rawValue: kind) }
    if state == .working || state == .blocked, let progress = pairs.values["progress"]?.last {
      report.progress = parseProgress(progress)
    }
    return report
  }

  /// A body's `key=value` pairs, in order. `raw` keeps every value for the
  /// limit and id checks, so a disallowed byte can't hide a value from them;
  /// `values` keeps only the ones a reader sees.
  private struct Pairs {
    var raw: [String: [String]] = [:]
    var values: [String: [String]] = [:]

    /// Nil when a key breaks its limit, even a key nobody reads.
    init?(_ bytes: [UInt8]) {
      for pair in bytes.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false) {
        guard let equals = pair.firstIndex(of: UInt8(ascii: "=")) else { continue }
        let key = ProgramStatusReport.trimmed(pair[pair.startIndex..<equals])
        guard key.count <= Limits.maxKeyBytes else { return nil }
        let value = ProgramStatusReport.trimmed(pair[pair.index(after: equals)...])
        // Splitting valid UTF-8 at ASCII bytes keeps both halves valid.
        guard let keyString = String(bytes: key, encoding: .utf8),
          let valueString = String(bytes: value, encoding: .utf8)
        else { continue }
        raw[keyString, default: []].append(valueString)
        guard value.allSatisfy(ProgramStatusReport.valueBytes.contains) else { continue }
        values[keyString, default: []].append(valueString)
      }
    }

    /// A malformed id discards the report instead of falling back to the root
    /// record, where `state=clear` would remove every record.
    var breaksALimit: Bool {
      if (raw["id"] ?? []).contains(where: { !ProgramStatusReport.isValidID($0) }) { return true }
      let limits = [
        ("app", Limits.maxAppBytes), ("title", Limits.maxTitleEncodedBytes), ("msg", Limits.maxMessageEncodedBytes),
      ]
      return limits.contains { key, limit in (raw[key] ?? []).contains { $0.utf8.count > limit } }
    }
  }

  private static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    var slice = bytes
    while let first = slice.first, asciiWhitespace.contains(first) { slice = slice.dropFirst() }
    while let last = slice.last, asciiWhitespace.contains(last) { slice = slice.dropLast() }
    return slice
  }

  private static func isName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy(nameBytes.contains)
  }

  /// Names joined by single slashes, within the length and depth limits.
  static func isValidID(_ id: String) -> Bool {
    guard id.utf8.count <= Limits.maxIDBytes else { return false }
    let segments = id.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count <= Limits.maxIDDepth else { return false }
    return segments.allSatisfy { $0.utf8.count <= Limits.maxIDSegmentBytes && isName(String($0)) }
  }

  /// A whole number from 0 to 100, digits only. Anything else is indeterminate.
  private static func parseProgress(_ value: String) -> Int? {
    guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
    guard let number = Int(value), number <= 100 else { return nil }
    return number
  }

  /// Base64 with optional padding, decoding to UTF-8 with no C0, DEL, or C1
  /// control character, at most `maxMessageBytes` long.
  static func decodeText(_ encoded: String) -> String? {
    let remainder = encoded.utf8.count % 4
    guard remainder != 1, remainder == 0 || !encoded.hasSuffix("=") else { return nil }
    let padded = remainder == 0 ? encoded : encoded + String(repeating: "=", count: 4 - remainder)
    guard let data = Data(base64Encoded: padded), data.count <= Limits.maxMessageBytes,
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    let isSafe = text.unicodeScalars.allSatisfy { scalar in
      switch scalar.value {
      case 0x00...0x1F, 0x7F, 0x80...0x9F: false
      default: true
      }
    }
    return isSafe ? text : nil
  }
}
