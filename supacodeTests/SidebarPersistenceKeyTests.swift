import Dependencies
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SidebarPersistenceKeyTests {
  @Test func groupHighlightRowsDefaultsOn() {
    // First-launch discoverability contract for the View-menu submenu: both
    // Group Pinned Rows and Group Active Rows must be visible by default so
    // users see the highlight feature without opening the menu.
    @Shared(.sidebarGroupPinnedRows) var groupPinned
    @Shared(.sidebarGroupActiveRows) var groupActive
    #expect(groupPinned == true)
    #expect(groupActive == true)
  }

  @Test func sortRepositoriesByNameDefaultsOff() {
    // A–Z is a view overlay on top of curated drag order. Defaulting it on
    // would silently reshuffle every existing sidebar on upgrade.
    @Shared(.sidebarSortRepositoriesByName) var sortByName
    #expect(sortByName == false)
  }

  @Test func corruptBlobFallsBackToEmptyAndStashesItAside() {
    // A garbage UserDefaults value must decode-fail into the empty default (never
    // crash or wedge the sidebar), and the bytes must be preserved for recovery.
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Dependency(\.defaultAppStorage) var store
      let garbage = Data("this-is-not-json".utf8)
      store.set(garbage, forKey: SidebarKey.storageKey)
      @Shared(.sidebar) var sidebar
      #expect(sidebar == SidebarState())
      #expect(store.data(forKey: SidebarKey.storageKey + ".corrupt") == garbage)
    }
  }

  @Test func savePersistsToUserDefaultsBlob() throws {
    try withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      @Shared(.sidebar) var sidebar
      $sidebar.withLock { $0.schemaVersion = 3 }

      @Dependency(\.defaultAppStorage) var store
      let data = try #require(store.data(forKey: SidebarKey.storageKey))
      let decoded = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(decoded.schemaVersion == 3)
    }
  }
}
