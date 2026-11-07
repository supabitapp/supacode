import GhosttyKit

nonisolated extension ProgramStatusReport {
  /// A report libghostty already validated. Nil only for a state this build
  /// doesn't know, which a newer libghostty could send.
  init?(_ status: ghostty_action_program_status_s) {
    guard let state = State(status.state) else { return nil }
    self.init(state: state, id: Self.text(status.id) ?? "")
    kind = Kind(status.kind)
    progress = status.progress >= 0 ? Int(status.progress) : nil
    app = Self.text(status.app)
    title = Self.text(status.title)
    message = Self.text(status.msg)
  }

  /// libghostty sends an empty string for a key the report didn't carry.
  private static func text(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let text = String(cString: pointer)
    return text.isEmpty ? nil : text
  }
}

nonisolated extension ProgramStatusReport.State {
  init?(_ state: ghostty_action_program_status_state_e) {
    switch state {
    case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_IDLE: self = .idle
    case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_WORKING: self = .working
    case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_DONE: self = .done
    case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_BLOCKED: self = .blocked
    case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_ERROR: self = .error
    case GHOSTTY_ACTION_PROGRAM_STATUS_STATE_CLEAR: self = .clear
    default: return nil
    }
  }
}

nonisolated extension ProgramStatusReport.Kind {
  init?(_ kind: ghostty_action_program_status_kind_e) {
    switch kind {
    case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_PERMISSION: self = .permission
    case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_QUESTION: self = .question
    case GHOSTTY_ACTION_PROGRAM_STATUS_KIND_AUTH: self = .auth
    default: return nil
    }
  }
}
