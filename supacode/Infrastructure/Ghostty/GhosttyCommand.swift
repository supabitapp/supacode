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

extension GhosttyCommand {
  private static let topologyActionPrefixes = [
    "new_tab", "close_tab", "goto_tab", "move_tab",
    "new_split", "goto_split", "resize_split", "equalize_splits", "toggle_split_zoom",
    "new_window", "close_window", "close_all_windows", "toggle_tab_overview",
  ]

  /// Whether the command would drive layout topology; the app owns those
  /// commands, and the conduit ignores their surface-emitted actions.
  var isTopologyCommand: Bool {
    Self.topologyActionPrefixes.contains { action == $0 || action.hasPrefix($0 + ":") }
  }
}
