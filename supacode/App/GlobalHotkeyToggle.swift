// Pure decision for the global visibility hotkey: hide only when the app is
// frontmost with a main window already in view, otherwise surface it.
enum GlobalHotkeyToggle {
  enum Decision: Equatable {
    case hide
    case show
  }

  static func resolve(isActive: Bool, hasVisibleMain: Bool) -> Decision {
    isActive && hasVisibleMain ? .hide : .show
  }
}
