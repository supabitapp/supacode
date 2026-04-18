import Dependencies
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SidebarPersistenceMigratorTests {
  @Test(.dependencies) func noopWhenSidebarFileAlreadyExists() async throws {
    let storage = InMemorySettingsFileStorage()
    try storage.save(Data(#"{}"#.utf8), SupacodePaths.sidebarURL)
    let existingBytes = try storage.load(SupacodePaths.sidebarURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = UserDefaults(suiteName: "\(#function).\(UUID().uuidString)")!
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      $legacyOrder.withLock { $0 = ["/tmp/repo-a"] }

      SidebarPersistenceMigrator.migrateIfNeeded(fileExists: { _ in true })

      // File untouched — still the bytes we seeded — and legacy
      // UserDefaults blob untouched since the migrator short-
      // circuited on file existence.
      #expect((try? storage.load(SupacodePaths.sidebarURL)) == existingBytes)
      #expect(legacyOrder == ["/tmp/repo-a"])
    }
  }

  @Test(.dependencies) func migratesCollapsePinOrderArchiveFocus() async throws {
    let storage = InMemorySettingsFileStorage()
    let archivedAt = Date(timeIntervalSince1970: 1_000_000)
    let suiteName = "\(#function).\(UUID().uuidString)"

    try await withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = UserDefaults(suiteName: suiteName)!
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) var legacyCollapsed: [String] = []
      @Shared(.appStorage("worktreeOrderByRepository")) var legacyWorktreeOrder: [String: [String]] = [:]
      @Shared(.appStorage("lastFocusedWorktreeID")) var legacyFocus: String? = nil
      @Shared(.appStorage("archivedWorktreeDates")) var legacyArchived: [String: Date] = [:]
      @Shared(.settingsFile) var settings

      $legacyOrder.withLock {
        $0 = ["/tmp/repo-a", "/tmp/repo-b"]
      }
      $legacyCollapsed.withLock {
        $0 = ["/tmp/repo-b"]
      }
      $legacyWorktreeOrder.withLock {
        $0 = [
          "/tmp/repo-a": ["/tmp/repo-a/wt-1", "/tmp/repo-a/wt-2"],
          "/tmp/repo-b": ["/tmp/repo-b/wt-3"],
        ]
      }
      $legacyFocus.withLock { $0 = "/tmp/repo-a/wt-2" }
      $legacyArchived.withLock { $0 = ["/tmp/repo-b/wt-3": archivedAt] }
      $settings.withLock {
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/wt-1"]
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b"]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(fileExists: { _ in false })

      // 1. The new `sidebar.json` file was written.
      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)

      let repoA = "/tmp/repo-a"
      let repoB = "/tmp/repo-b"
      // Sections preserve the legacy repo-order.
      #expect(Array(migrated.sections.keys) == [repoA, repoB])
      // repo-b is collapsed; repo-a is not.
      #expect(migrated.sections[repoA]?.collapsed == false)
      #expect(migrated.sections[repoB]?.collapsed == true)
      // wt-1 routes to `.pinned`; wt-2 stays in `.unpinned`.
      let repoAPinned = Array(migrated.sections[repoA]?.buckets[.pinned]?.items.keys ?? [])
      let repoAUnpinned = Array(migrated.sections[repoA]?.buckets[.unpinned]?.items.keys ?? [])
      #expect(repoAPinned == ["/tmp/repo-a/wt-1"])
      #expect(repoAUnpinned == ["/tmp/repo-a/wt-2"])
      // wt-3 routes to `.archived` (timestamp wins over `.unpinned`).
      #expect(migrated.sections[repoB]?.buckets[.unpinned]?.items["/tmp/repo-b/wt-3"] == nil)
      #expect(migrated.sections[repoB]?.buckets[.archived]?.items["/tmp/repo-b/wt-3"]?.archivedAt == archivedAt)
      // Focus carries through.
      #expect(migrated.focusedWorktreeID == "/tmp/repo-a/wt-2")

      // 2. Legacy sources cleared.
      #expect(legacyOrder.isEmpty)
      #expect(legacyCollapsed.isEmpty)
      #expect(legacyWorktreeOrder.isEmpty)
      #expect(legacyFocus == nil)
      #expect(legacyArchived.isEmpty)
      #expect(settings.pinnedWorktreeIDs.isEmpty)
    }
  }

  @Test(.dependencies) func rescuesOrphanPinnedViaPathPrefixMatch() async throws {
    let storage = InMemorySettingsFileStorage()
    let suiteName = "\(#function).\(UUID().uuidString)"

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = UserDefaults(suiteName: suiteName)!
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock {
        // No legacy row-order; just roots + a pinned ID.
        $0.repositoryRoots = ["/tmp/repo-a"]
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/feature"]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(fileExists: { _ in false })

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(migrated.sections["/tmp/repo-a"]?.buckets[.pinned]?.items["/tmp/repo-a/feature"] != nil)
    }
  }

  @Test func rescuePrefixMatchPicksLongestNestedRoot() {
    // `.local(/tmp/outer/inner/wt-1)` has two candidate roots;
    // the longest-wins rule must pick `/tmp/outer/inner` so
    // nested repo registrations don't collapse into the outer.
    let outer = ["/tmp/outer", "/tmp/outer/inner"]
    let reversed = ["/tmp/outer/inner", "/tmp/outer"]
    for roots in [outer, reversed] {
      let resolved = SidebarPersistenceMigrator.repositoryID(
        owningWorktreeID: "/tmp/outer/inner/wt-1",
        amongLegacyRoots: roots
      )
      #expect(resolved == "/tmp/outer/inner")
    }
  }

  @Test func rescuePrefixMatchRejectsNonParentPrefix() {
    // "/tmp/rep" is a string-prefix of "/tmp/repo" but NOT a
    // parent directory — the trailing-slash guard must reject
    // this match.
    let resolved = SidebarPersistenceMigrator.repositoryID(
      owningWorktreeID: "/tmp/repo/wt-1",
      amongLegacyRoots: ["/tmp/rep"]
    )
    #expect(resolved == nil)
  }

  @Test func rescuePrefixMatchHandlesTrailingSlashRoot() {
    // `URL(filePath:).standardizedFileURL.path(percentEncoded:)`
    // preserves trailing slashes for directory-styled inputs.
    // The migrator must strip them before building the guard
    // prefix; otherwise the concatenation `"/tmp/repo-a/" + "/"`
    // produces `"//"` which never matches a worktree path.
    let resolved = SidebarPersistenceMigrator.repositoryID(
      owningWorktreeID: "/tmp/repo-a/wt-1",
      amongLegacyRoots: ["/tmp/repo-a/"]
    )
    #expect(resolved == "/tmp/repo-a")
  }

  @Test func translateNormalisesPathsAndRejectsUnknownSchemes() {
    // Bare filesystem paths pass through as the standardized path.
    let bare = SidebarPersistenceMigrator.translate("/tmp/repo-a")
    #expect(bare == "/tmp/repo-a")
    // Redundant `.` components get collapsed.
    let normalised = SidebarPersistenceMigrator.translate("/tmp/./repo-a")
    #expect(normalised == "/tmp/repo-a")
    // A string with an unknown scheme is rejected so the
    // migrator doesn't coerce it into a bogus path key.
    let unknown = SidebarPersistenceMigrator.translate("custom://whatever")
    #expect(unknown == nil)
  }

  @Test(.dependencies) func writesEmptySidebarOnFreshInstall() async throws {
    let storage = InMemorySettingsFileStorage()
    let suiteName = "\(#function).\(UUID().uuidString)"

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = UserDefaults(suiteName: suiteName)!
    } operation: {
      SidebarPersistenceMigrator.migrateIfNeeded(fileExists: { _ in false })

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(migrated.sections.isEmpty)
      #expect(migrated.focusedWorktreeID == nil)
    }
  }
}
