/// Where Supacode shows up on the system: the Dock, the menu bar, or both.
/// At least one surface is always enabled — there is no "hidden everywhere"
/// case — so the app is never unreachable.
public enum AppVisibility: String, CaseIterable, Identifiable, Codable, Sendable {
  case dock
  case dockAndMenuBar
  case menuBar

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .dock: "Dock"
    case .dockAndMenuBar: "Dock & Menu Bar"
    case .menuBar: "Menu Bar"
    }
  }

  /// SF Symbol used by the settings option cards. Placeholder art until a
  /// dedicated asset lands; conveys "dock" / "both" / "menu bar" at a glance.
  public var symbolName: String {
    switch self {
    case .dock: "dock.rectangle"
    case .dockAndMenuBar: "menubar.dock.rectangle"
    case .menuBar: "menubar.rectangle"
    }
  }

  /// True when this mode keeps the menu bar status item inserted.
  public var showsMenuBarIcon: Bool {
    self == .dockAndMenuBar || self == .menuBar
  }

  /// True when this mode hides the Dock icon (runs as an accessory app).
  public var hidesDockIcon: Bool {
    self == .menuBar
  }
}
