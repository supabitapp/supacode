import GhosttyKit

struct GhosttyCommand: Equatable, Sendable {
  let title: String
  let description: String
  let action: String
  let actionKey: String

  init(
    title: String,
    description: String,
    action: String,
    actionKey: String
  ) {
    self.title = title
    self.description = description
    self.action = action
    self.actionKey = actionKey
  }

  init(cValue: ghostty_command_s) {
    self.init(
      title: String(cString: cValue.title),
      description: String(cString: cValue.description),
      action: String(cString: cValue.action),
      actionKey: String(cString: cValue.action_key)
    )
  }
}
