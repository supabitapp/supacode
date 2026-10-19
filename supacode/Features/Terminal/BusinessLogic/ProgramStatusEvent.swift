import Foundation
import GhosttyKit

/// One OSC 7501 (Program Status Protocol) report, copied out of Ghostty's
/// action callback. The program's text is untrusted and must never be logged.
nonisolated struct ProgramStatusReport: Equatable, Sendable {
  enum State: String, Equatable, Sendable {
    case idle
    case working
    case done
    case blocked
    case error

    /// `working` and `blocked` end when the program does; `idle` may.
    var endsWithProgram: Bool { self != .done && self != .error }
  }

  enum Kind: String, Equatable, Sendable {
    case permission
    case question
    case auth
  }

  /// Empty for the root record; `/` nests records, so `build/test` is a child of `build`.
  var id: String
  var state: State
  /// Only set for `.blocked`.
  var kind: Kind?
  /// 0 through 100; nil is indeterminate.
  var progress: Int?
  var app: String?
  var title: String?
  var message: String?
}

/// What a surface's program status records react to, in stream order: a
/// report, a `clear` of a record and its children, or an OSC 133 boundary
/// the protocol's lifetime rules hang off.
nonisolated enum ProgramStatusEvent: Equatable, Sendable {
  case report(ProgramStatusReport)
  /// Removes the record and its children; the root id (empty) removes every record.
  case clear(id: String)
  case promptStart
  case commandStart
  case commandEnd
}

extension ProgramStatusEvent {
  /// Nil for a value this build doesn't know, so a newer Ghostty can't turn
  /// into a different event.
  init?(_ value: ghostty_action_program_status_s) {
    switch value.event {
    case GHOSTTY_PROGRAM_STATUS_EVENT_PROMPT_START: self = .promptStart
    case GHOSTTY_PROGRAM_STATUS_EVENT_COMMAND_START: self = .commandStart
    case GHOSTTY_PROGRAM_STATUS_EVENT_COMMAND_END: self = .commandEnd
    case GHOSTTY_PROGRAM_STATUS_EVENT_REPORT where value.state == GHOSTTY_PROGRAM_STATUS_STATE_CLEAR:
      self = .clear(id: ProgramStatusReport.string(value.id) ?? "")
    case GHOSTTY_PROGRAM_STATUS_EVENT_REPORT:
      guard let report = ProgramStatusReport(value) else { return nil }
      self = .report(report)
    default:
      return nil
    }
  }
}

extension ProgramStatusReport {
  init?(_ value: ghostty_action_program_status_s) {
    guard let state = State(value.state) else { return nil }
    self.init(
      id: Self.string(value.id) ?? "",
      state: state,
      kind: state == .blocked ? Kind(value.kind) : nil,
      progress: (0...100).contains(value.progress) ? Int(value.progress) : nil,
      app: Self.string(value.app),
      title: Self.string(value.title),
      message: Self.string(value.message)
    )
  }

  /// Ghostty sends empty strings, never NULL, for absent values.
  fileprivate static func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer, pointer.pointee != 0 else { return nil }
    return String(cString: pointer)
  }
}

extension ProgramStatusReport.State {
  init?(_ value: ghostty_action_program_status_state_e) {
    switch value {
    case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: self = .idle
    case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: self = .working
    case GHOSTTY_PROGRAM_STATUS_STATE_DONE: self = .done
    case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: self = .blocked
    case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: self = .error
    default: return nil
    }
  }
}

extension ProgramStatusReport.Kind {
  init?(_ value: ghostty_action_program_status_kind_e) {
    switch value {
    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: self = .permission
    case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: self = .question
    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: self = .auth
    default: return nil
    }
  }
}
