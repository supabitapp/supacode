/// Where Supacode shows up on the system: the Dock, the menu bar, or both.
/// Every case keeps at least one surface enabled (there is no "hidden
/// everywhere" case), so the app is never unreachable.
public enum AppVisibility: String, CaseIterable, Identifiable, Codable, Sendable {
  case dock
  case menuBar
  case dockAndMenuBar

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .dock: "Dock"
    case .menuBar: "Menu Bar"
    case .dockAndMenuBar: "Both"
    }
  }

  public var help: String {
    switch self {
    case .dock: "Show Supacode in the Dock only."
    case .menuBar: "Show Supacode in the menu bar only, with no Dock icon."
    case .dockAndMenuBar: "Show Supacode in both the Dock and the menu bar."
    }
  }

  public var imageName: String {
    switch self {
    case .dock: "VisibilityDock"
    case .menuBar: "VisibilityMenuBar"
    case .dockAndMenuBar: "VisibilityBoth"
    }
  }

  public var showsMenuBarIcon: Bool {
    self == .dockAndMenuBar || self == .menuBar
  }

  public var showsDockIcon: Bool {
    self != .menuBar
  }

  /// Hiding the Dock icon means running as an accessory app.
  public var hidesDockIcon: Bool {
    !showsDockIcon
  }
}
