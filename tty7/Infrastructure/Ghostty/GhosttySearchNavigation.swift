enum GhosttySearchDirection {
  case next
  case previous

  var bindingAction: String {
    switch self {
    case .next:
      return "navigate_search:next"
    case .previous:
      return "navigate_search:previous"
    }
  }

  var oppositeBindingAction: String {
    switch self {
    case .next:
      return "navigate_search:previous"
    case .previous:
      return "navigate_search:next"
    }
  }
}

enum GhosttySearchNavigator {
  static func bindingActions(
    direction: GhosttySearchDirection,
    selected: Int?,
    total: Int?
  ) -> [String] {
    let directAction = direction.bindingAction
    guard let total, let selected, total > 1, selected >= 0, selected < total else {
      return [directAction]
    }

    switch direction {
    case .next where selected == total - 1:
      return Array(repeating: direction.oppositeBindingAction, count: total - 1)
    case .previous where selected == 0:
      return Array(repeating: direction.oppositeBindingAction, count: total - 1)
    default:
      return [directAction]
    }
  }
}

extension GhosttySurfaceView {
  func navigateSearch(_ direction: GhosttySearchDirection) {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: direction,
      selected: bridge.state.searchSelected,
      total: bridge.state.searchTotal
    )
    for action in actions {
      performBindingAction(action)
    }
  }
}
