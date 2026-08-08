struct TerminalTabContextMenuActions {
  let closeTab: (TabID) -> Void
  let closeOthers: (TabID) -> Void
  let closeToRight: (TabID) -> Void
  let closeAll: () -> Void
  let renameTab: (TabID) -> Void
}
