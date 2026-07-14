import Testing

@testable import SupacodeSettingsShared

struct AppVisibilityTests {
  /// The whole point of the three-case model: no mode may hide the app from
  /// both surfaces at once, which would leave it unreachable.
  @Test func everyModeKeepsAtLeastOneSurfaceEnabled() {
    for visibility in AppVisibility.allCases {
      #expect(visibility.showsDockIcon || visibility.showsMenuBarIcon)
    }
  }

  @Test func onlyMenuBarModeRunsAsAnAccessory() {
    #expect(AppVisibility.menuBar.hidesDockIcon)
    #expect(!AppVisibility.dock.hidesDockIcon)
    #expect(!AppVisibility.dockAndMenuBar.hidesDockIcon)
  }

  @Test func menuBarIconIsInsertedForBothMenuBarModes() {
    #expect(AppVisibility.menuBar.showsMenuBarIcon)
    #expect(AppVisibility.dockAndMenuBar.showsMenuBarIcon)
    #expect(!AppVisibility.dock.showsMenuBarIcon)
  }

  /// Raw values are persisted, so reordering or renaming a case must not
  /// silently repoint an existing settings file at a different mode.
  @Test func rawValuesAreStable() {
    #expect(AppVisibility(rawValue: "dock") == .dock)
    #expect(AppVisibility(rawValue: "menuBar") == .menuBar)
    #expect(AppVisibility(rawValue: "dockAndMenuBar") == .dockAndMenuBar)
  }

  @Test func cardsReadDockThenMenuBarThenBoth() {
    #expect(AppVisibility.allCases.map(\.title) == ["Dock", "Menu Bar", "Both"])
  }

  @Test func everyCardHasArtwork() {
    #expect(
      AppVisibility.allCases.map(\.imageName)
        == ["VisibilityDock", "VisibilityMenuBar", "VisibilityBoth"]
    )
  }
}
