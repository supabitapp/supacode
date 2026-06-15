enum GhosttySplitAction {
  enum NewDirection {
    case left
    case right
    case top
    case down
  }

  enum FocusDirection {
    case previous
    case next
    case left
    case right
    case top
    case down
  }

  enum ResizeDirection {
    case left
    case right
    case top
    case down
  }

  case newSplit(direction: NewDirection)
  case gotoSplit(direction: FocusDirection)
  case resizeSplit(direction: ResizeDirection, amount: UInt16)
  case equalizeSplits
  case toggleSplitZoom
}
