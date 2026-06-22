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
  @Test(.dependencies) func noopWhenSidebarFileAlreadyExists() throws {
    let storage = InMemorySettingsFileStorage()
    // Seed a migrated-schema file so the idempotency gate short-
    // circuits. An empty `{}` would decode with `schemaVersion == 0`
    // and (correctly) trigger a re-migration.
    let encoder = JSONEncoder()
    var seeded = SidebarState()
    seeded.schemaVersion = 1
    let seededBytes = try encoder.encode(seeded)
    try storage.save(seededBytes, SupacodePaths.sidebarURL)
    let existingBytes = try storage.load(SupacodePaths.sidebarURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      $legacyOrder.withLock { $0 = ["/tmp/repo-a"] }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in true },
        readFile: { try? storage.load($0) }
      )

      // File untouched — still the bytes we seeded — and legacy
      // UserDefaults blob untouched since the migrator short-
      // circuited on the schemaVersion idempotency gate.
      #expect((try? storage.load(SupacodePaths.sidebarURL)) == existingBytes)
      #expect(legacyOrder == ["/tmp/repo-a"])
    }
  }

  @Test(.dependencies) func migratesCollapsePinOrderArchiveFocus() throws {
    let storage = InMemorySettingsFileStorage()
    let archivedAt = Date(timeIntervalSince1970: 1_000_000)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) var legacyCollapsed: [String] = []
      @Shared(.appStorage("worktreeOrderByRepository")) var legacyWorktreeOrder: [String: [String]] = [:]
      @Shared(.appStorage("lastFocusedWorktreeID")) var legacyFocus: String?
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

      let repoA: Repository.ID = "/tmp/repo-a"
      let repoB: Repository.ID = "/tmp/repo-b"
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

  @Test(.dependencies) func rescuesOrphanPinnedViaPathPrefixMatch() throws {
    let storage = InMemorySettingsFileStorage()

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
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
    // `repositoryID(...)` now expects pre-normalised inputs on
    // both sides — route the raw paths through
    // `RepositoryPathNormalizer.normalize(_:)` first so the test
    // pins the canonical-in/canonical-out contract end to end.
    let worktreeID = WorktreeID(RepositoryPathNormalizer.normalize("/tmp/outer/inner/wt-1")!)
    let outer = RepositoryPathNormalizer.normalize(["/tmp/outer", "/tmp/outer/inner"])
    let reversed = RepositoryPathNormalizer.normalize(["/tmp/outer/inner", "/tmp/outer"])
    let expected = RepositoryID(RepositoryPathNormalizer.normalize("/tmp/outer/inner")!)
    for roots in [outer, reversed] {
      let candidates = roots.map { (candidate: $0, owningRoot: $0) }
      let resolved = SidebarPersistenceMigrator.repositoryID(
        owningWorktreeID: worktreeID,
        amongLegacyRoots: candidates
      )
      #expect(resolved == expected)
    }
  }

  @Test func rescuePrefixMatchRejectsNonParentPrefix() {
    // "/tmp/rep" is a string-prefix of "/tmp/repo" but NOT a
    // parent directory — the trailing-slash guard must reject
    // this match. Pre-normalise both sides to match the new
    // canonical-input contract of `repositoryID(...)`.
    let worktreeID = WorktreeID(RepositoryPathNormalizer.normalize("/tmp/repo/wt-1")!)
    let roots = RepositoryPathNormalizer.normalize(["/tmp/rep"])
    let candidates = roots.map { (candidate: $0, owningRoot: $0) }
    let resolved = SidebarPersistenceMigrator.repositoryID(
      owningWorktreeID: worktreeID,
      amongLegacyRoots: candidates
    )
    #expect(resolved == nil)
  }

  @Test func rescuePrefixMatchHandlesTrailingSlashRoot() {
    // `URL(filePath:).standardizedFileURL.path(percentEncoded:)`
    // preserves trailing slashes for directory-styled inputs.
    // The migrator must strip them before building the guard
    // prefix; otherwise the concatenation `"/tmp/repo-a/" + "/"`
    // produces `"//"` which never matches a worktree path.
    // `repositoryID(...)` now returns the caller-supplied
    // `owningRoot` as-is once a candidate matches — live callers
    // always pass the canonical `Repository.ID` there, so echoing
    // it unchanged keeps downstream section-key lookups honest.
    let worktreeID = WorktreeID(RepositoryPathNormalizer.normalize("/tmp/repo-a/wt-1")!)
    let roots = RepositoryPathNormalizer.normalize(["/tmp/repo-a/"])
    let candidates = roots.map { (candidate: $0, owningRoot: $0) }
    let resolved = SidebarPersistenceMigrator.repositoryID(
      owningWorktreeID: worktreeID,
      amongLegacyRoots: candidates
    )
    #expect(resolved == roots.first.map(RepositoryID.init))
  }

  @Test func normalizerRejectsEmptyAndWhitespaceAndCollapsesDotComponents() {
    // Replaces the retired `translate(_:)` helper: pin the new
    // canonical single-path normaliser's rejection semantics
    // (empty / whitespace-only → `nil`) plus the standardised-
    // path collapsing that `URL(fileURLWithPath:).standardizedFileURL`
    // performs. `RepositoryPathNormalizer.normalize(_:)` does NOT
    // inspect scheme strings — `URL(fileURLWithPath:)` treats
    // `"custom://whatever"` as a literal filesystem path, so the
    // old "reject unknown schemes" guarantee does not survive the
    // rewrite. Documented here so future readers don't assume the
    // old behaviour still holds.
    #expect(RepositoryPathNormalizer.normalize("/tmp/repo-a") == "/tmp/repo-a")
    #expect(RepositoryPathNormalizer.normalize("/tmp/./repo-a") == "/tmp/repo-a")
    #expect(RepositoryPathNormalizer.normalize("") == nil)
    #expect(RepositoryPathNormalizer.normalize("   ") == nil)
    #expect(RepositoryPathNormalizer.normalize("\n\t") == nil)
  }

  @Test(.dependencies) func migrationStampsSchemaVersion1OnWriteSuccess() throws {
    let storage = InMemorySettingsFileStorage()

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      $legacyOrder.withLock { $0 = ["/tmp/repo-a"] }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(migrated.schemaVersion == 1)
    }
  }

  @Test(.dependencies) func migratorRerunsWhenFileHasSchemaVersionZero() throws {
    let storage = InMemorySettingsFileStorage()
    // Pre-seed `sidebar.json` with an empty `SidebarState()` — its
    // `schemaVersion` defaults to `0`, simulating a file that was
    // created by a `@Shared(.sidebar)` mutation before the migrator
    // ever landed its write (e.g. because a previous migration run
    // crashed between allocating the shared state and persisting).
    let encoder = JSONEncoder()
    let priorBytes = try encoder.encode(SidebarState())
    try storage.save(priorBytes, SupacodePaths.sidebarURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      $legacyOrder.withLock { $0 = ["/tmp/repo-a"] }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in true },
        readFile: { try? storage.load($0) }
      )

      // Migration actually ran: legacy got folded AND the file now
      // carries `schemaVersion == 1`.
      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(migrated.schemaVersion == 1)
      #expect(Array(migrated.sections.keys) == ["/tmp/repo-a"])
      #expect(legacyOrder.isEmpty)
    }
  }

  @Test(.dependencies) func migratorSkipsWhenFileAlreadyHasSchemaVersion1() throws {
    let storage = InMemorySettingsFileStorage()
    // Pre-seed a migrated file with a recognizable section so we can
    // verify the bytes are untouched after a skipped migration.
    var seeded = SidebarState()
    seeded.schemaVersion = 1
    seeded.sections["/tmp/already-migrated"] = .init()
    let encoder = JSONEncoder()
    let seededBytes = try encoder.encode(seeded)
    try storage.save(seededBytes, SupacodePaths.sidebarURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      $legacyOrder.withLock { $0 = ["/tmp/repo-a"] }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in true },
        readFile: { try? storage.load($0) }
      )

      // File bytes untouched.
      #expect((try? storage.load(SupacodePaths.sidebarURL)) == seededBytes)
      // Legacy UserDefaults untouched since the migrator skipped.
      #expect(legacyOrder == ["/tmp/repo-a"])
    }
  }

  @Test(.dependencies) func migratorFoldsSettingsFilePinnedWorktreeIDsIntoSidebar() throws {
    // Pins `@Shared(.settingsFile)` as a live hydration dependency:
    // if a future async-settings refactor lets this access return
    // before `pinnedWorktreeIDs` / `repositoryRoots` land, the
    // migrator would silently drop curation and this test would
    // catch it.
    let storage = InMemorySettingsFileStorage()

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock {
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b"]
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/feature", "/tmp/repo-b/bugfix"]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)

      #expect(
        migrated.sections["/tmp/repo-a"]?.buckets[.pinned]?.items["/tmp/repo-a/feature"] != nil
      )
      #expect(
        migrated.sections["/tmp/repo-b"]?.buckets[.pinned]?.items["/tmp/repo-b/bugfix"] != nil
      )
      // Legacy pinned list on the settings file was cleared once the
      // bucketed form took ownership.
      #expect(settings.pinnedWorktreeIDs.isEmpty)
    }
  }

  @Test(.dependencies) func migratorFoldsPre214ArchivedWorktreeIDsWithInjectedNow() throws {
    // T1 — pre-#214 archive migration. The retired
    // `ArchivedWorktreeDatesClient.liveValue.load` used to fold a
    // bare `[String]` ID list into `archivedWorktreeDates` on
    // first read; the migrator now inherits that job. Seed ONLY
    // the legacy ID list (no dated dictionary, no row order) plus
    // the owning root so the rescue pass can place the entries,
    // then assert the migrated `sidebar.json` has both worktrees
    // in `.archived` stamped with the injected `date.now`, and
    // the legacy ID list cleared post-write.
    let storage = InMemorySettingsFileStorage()
    let injectedNow = Date(timeIntervalSince1970: 1_700_000_000)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      $0.date.now = injectedNow
    } operation: {
      @Shared(.appStorage("archivedWorktreeIDs")) var legacyArchivedIDs: [String] = []
      @Shared(.appStorage("archivedWorktreeDates")) var legacyArchived: [String: Date] = [:]
      @Shared(.settingsFile) var settings
      $settings.withLock {
        $0.repositoryRoots = ["/tmp/repo-a"]
      }
      $legacyArchivedIDs.withLock {
        $0 = ["/tmp/repo-a/wt-1", "/tmp/repo-a/wt-2"]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      let archived = migrated.sections["/tmp/repo-a"]?.buckets[.archived]?.items
      #expect(archived?["/tmp/repo-a/wt-1"]?.archivedAt == injectedNow)
      #expect(archived?["/tmp/repo-a/wt-2"]?.archivedAt == injectedNow)
      // Legacy ID list cleared post-write — the migrator is the
      // last reader of that key and must drop it once the
      // timestamps land in the bucketed archive.
      #expect(legacyArchivedIDs.isEmpty)
      // Dated dictionary was empty on input and should stay empty
      // after the fold (the migrator folds straight into the
      // bucketed `.archived` collection, not back into the legacy
      // dated dictionary).
      #expect(legacyArchived.isEmpty)
    }
  }

  @Test(.dependencies) func migratorSeedsBaselineSectionOrderFromRepositoryRoots() throws {
    // T2 — baseline order from `repositoryRoots`. When the user
    // never curated a row order (`repositoryOrderIDs` empty,
    // `worktreeOrderByRepository` empty), `sidebar.json` must
    // still materialise one empty section per known root, in
    // settings order, so repos with only a main worktree stay
    // visible after migration.
    let storage = InMemorySettingsFileStorage()

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock {
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b", "/tmp/repo-c"]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(Array(migrated.sections.keys) == ["/tmp/repo-a", "/tmp/repo-b", "/tmp/repo-c"])
      for (_, section) in migrated.sections {
        // Every seeded section is empty: no curated buckets,
        // collapse bit defaulted, ready for the reducer's seed
        // pass to fill in `.unpinned` once worktrees hydrate.
        #expect(section.buckets.isEmpty)
        #expect(section.collapsed == false)
      }
    }
  }

  @Test(.dependencies) func migratorLegacyOrderMovesMatchingRootsToTopAndAppendsRest() throws {
    // T3 — `legacyOrder` override layer. Baseline is
    // `repositoryRoots` in settings order; `repositoryOrderIDs`
    // applies as a move-to-top override so repos the user
    // explicitly curated win. Roots present in settings but
    // missing from `legacyOrder` append in settings order after
    // the curated prefix; duplicates in `legacyOrder` stay unique.
    let storage = InMemorySettingsFileStorage()

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
      $settings.withLock {
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b", "/tmp/repo-c", "/tmp/repo-d"]
      }
      $legacyOrder.withLock {
        $0 = ["/tmp/repo-c", "/tmp/repo-a"]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(
        Array(migrated.sections.keys) == [
          "/tmp/repo-c",
          "/tmp/repo-a",
          "/tmp/repo-b",
          "/tmp/repo-d",
        ]
      )
    }
  }

  @Test(.dependencies) func migratorNormalisesNonCanonicalPathsIntoCanonicalSectionKeys() throws {
    // T4 — non-canonical path normalisation. Seed
    // `repositoryRoots` and `pinnedWorktreeIDs` with paths that
    // differ from their canonical form (redundant `.` components
    // and a trailing slash — the two shapes this branch's
    // `RepositoryPathNormalizer.normalize(_:)` is known to
    // canonicalise). Assert every section key + pinned key in
    // the migrated `sidebar.json` matches
    // `RepositoryPathNormalizer.normalize(_:)` output, so
    // downstream `Repository.ID` string comparisons line up
    // regardless of which shape the user originally typed.
    let storage = InMemorySettingsFileStorage()
    let nonCanonicalRoot = "/tmp/./repo-a"
    let nonCanonicalWorktree = "/tmp/./repo-a/feature"
    let canonicalRoot = RepositoryPathNormalizer.normalize(nonCanonicalRoot)!
    let canonicalWorktree = RepositoryPathNormalizer.normalize(nonCanonicalWorktree)!
    // Sanity-check the fixture: the raw inputs MUST differ from
    // their canonical shapes, otherwise the test degenerates into
    // a tautology that would quietly pass if the normaliser
    // regressed to `identity`.
    #expect(nonCanonicalRoot != canonicalRoot)
    #expect(nonCanonicalWorktree != canonicalWorktree)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      // Bypass `RepositoryRootsKey` / `PinnedWorktreeIDsKey`'s
      // `save(...)` path (which normalises on write) by mutating
      // the backing `.settingsFile` directly — the migrator must
      // be robust against already-persisted non-canonical bytes
      // sitting on disk from an older build.
      $settings.withLock {
        $0.repositoryRoots = [nonCanonicalRoot]
        $0.pinnedWorktreeIDs = [nonCanonicalWorktree]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      // Section keyed on the canonical repo ID, and the pinned
      // worktree lives in that section's `.pinned` bucket under
      // its own canonical key.
      #expect(Array(migrated.sections.keys) == [RepositoryID(canonicalRoot)])
      let pinnedItems = migrated.sections[RepositoryID(canonicalRoot)]?.buckets[.pinned]?.items
      #expect(pinnedItems?[WorktreeID(canonicalWorktree)] != nil)
      // Non-canonical spellings must NOT leak into the migrated
      // state — otherwise string comparisons against live
      // `Repository.ID` / `Worktree.ID` would drift depending on
      // which code path inserted the row.
      #expect(migrated.sections[RepositoryID(nonCanonicalRoot)] == nil)
      #expect(pinnedItems?[WorktreeID(nonCanonicalWorktree)] == nil)
    }
  }

  @Test(.dependencies) func rescuesOrphanPinnedViaDefaultWorktreeBaseConvention() throws {
    // T6 — default `~/.supacode/repos/<name>/` convention. The
    // legacy pinned path lives under the convention base, which
    // shares no common ancestor with the repo root stored in
    // `repositoryRoots`. The new `rootCandidates(...)` helper must
    // emit the convention base as a candidate paired with the
    // owning root so prefix-matching places the pin correctly.
    let storage = InMemorySettingsFileStorage()
    let rootURL = URL(fileURLWithPath: "/Developer/X/foo", isDirectory: true)
    let owningRootID = RepositoryID(
      RepositoryPathNormalizer.normalize(rootURL.path(percentEncoded: false))!
    )
    // Pin lives under the default convention base — derive the
    // exact path from `SupacodePaths` so the expectation matches
    // whatever `worktreeBaseDirectory(...)` produces at runtime.
    let conventionBase = SupacodePaths.worktreeBaseDirectory(
      for: rootURL,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )
    let pinnedPath =
      conventionBase
      .appending(path: "sbertix", directoryHint: .isDirectory)
      .appending(path: "branch-a", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let canonicalPinnedID = WorktreeID(RepositoryPathNormalizer.normalize(pinnedPath)!)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock {
        $0.repositoryRoots = [rootURL.path(percentEncoded: false)]
        $0.pinnedWorktreeIDs = [pinnedPath]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(
        migrated.sections[owningRootID]?.buckets[.pinned]?.items[canonicalPinnedID] != nil
      )
    }
  }

  @Test(.dependencies) func rescuesOrphanPinnedViaGlobalWorktreeBaseOverride() throws {
    // T7 — global `defaultWorktreeBaseDirectoryPath` override. The
    // effective base is `<globalBase>/<root.lastPathComponent>/`
    // and the pin sits directly under it; the candidate pool must
    // include the global-override base paired with the owning
    // root.
    let storage = InMemorySettingsFileStorage()
    let rootURL = URL(fileURLWithPath: "/Developer/X/foo", isDirectory: true)
    let owningRootID = RepositoryID(
      RepositoryPathNormalizer.normalize(rootURL.path(percentEncoded: false))!
    )
    let globalBase = "/tmp/shared-worktrees"
    let overrideBase = SupacodePaths.worktreeBaseDirectory(
      for: rootURL,
      globalDefaultPath: globalBase,
      repositoryOverridePath: nil
    )
    let pinnedPath =
      overrideBase
      .appending(path: "branch-a", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let canonicalPinnedID = WorktreeID(RepositoryPathNormalizer.normalize(pinnedPath)!)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock {
        $0.global.defaultWorktreeBaseDirectoryPath = globalBase
        $0.repositoryRoots = [rootURL.path(percentEncoded: false)]
        $0.pinnedWorktreeIDs = [pinnedPath]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(
        migrated.sections[owningRootID]?.buckets[.pinned]?.items[canonicalPinnedID] != nil
      )
    }
  }

  @Test(.dependencies) func rescuesOrphanPinnedViaPerRepoWorktreeBaseOverride() throws {
    // T8 — per-repo `supacode.json` override. The migrator reads
    // the override synchronously via
    // `\.repositoryLocalSettingsStorage` (NOT the async
    // `@Shared(.repositorySettings(rootURL))` key) so the
    // migrator doesn't race the SharedKey hydration pipeline.
    let storage = InMemorySettingsFileStorage()
    let localSettingsStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/Developer/X/foo", isDirectory: true)
    let owningRootID = RepositoryID(
      RepositoryPathNormalizer.normalize(rootURL.path(percentEncoded: false))!
    )
    let overrideBase = "/Volumes/External/worktrees"
    let pinnedPath = URL(fileURLWithPath: overrideBase, isDirectory: true)
      .appending(path: "branch-a", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let canonicalPinnedID = WorktreeID(RepositoryPathNormalizer.normalize(pinnedPath)!)

    // Seed the per-repo `supacode.json` via the injected storage
    // so the migrator's synchronous load succeeds.
    var perRepoSettings = RepositorySettings.default
    perRepoSettings.worktreeBaseDirectoryPath = overrideBase
    let encoder = JSONEncoder()
    try localSettingsStorage.save(
      encoder.encode(perRepoSettings),
      at: SupacodePaths.repositorySettingsURL(for: rootURL)
    )

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.repositoryLocalSettingsStorage = localSettingsStorage.storage
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock {
        $0.repositoryRoots = [rootURL.path(percentEncoded: false)]
        $0.pinnedWorktreeIDs = [pinnedPath]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(
        migrated.sections[owningRootID]?.buckets[.pinned]?.items[canonicalPinnedID] != nil
      )
    }
  }

  @Test(.dependencies) func rescuesOrphanArchivedViaDefaultWorktreeBaseConvention() throws {
    // T9 — archived resolver via default convention. Mirrors T6
    // but for the archived-worktree fold: an entry sitting under
    // `~/.supacode/repos/<name>/` with a timestamp should land in
    // `.archived` on the settings root it belongs to.
    let storage = InMemorySettingsFileStorage()
    let rootURL = URL(fileURLWithPath: "/Developer/X/foo", isDirectory: true)
    let owningRootID = RepositoryID(
      RepositoryPathNormalizer.normalize(rootURL.path(percentEncoded: false))!
    )
    let conventionBase = SupacodePaths.worktreeBaseDirectory(
      for: rootURL,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )
    let archivedPath =
      conventionBase
      .appending(path: "sbertix", directoryHint: .isDirectory)
      .appending(path: "branch-a", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    let canonicalArchivedID = WorktreeID(RepositoryPathNormalizer.normalize(archivedPath)!)
    let archivedAt = Date(timeIntervalSince1970: 1_000_000)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settings
      @Shared(.appStorage("archivedWorktreeDates")) var legacyArchived: [String: Date] = [:]
      $settings.withLock {
        $0.repositoryRoots = [rootURL.path(percentEncoded: false)]
      }
      $legacyArchived.withLock {
        $0 = [archivedPath: archivedAt]
      }

      SidebarPersistenceMigrator.migrateIfNeeded(
        fileExists: { _ in false },
        readFile: { try? storage.load($0) }
      )

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      let archived = migrated.sections[owningRootID]?.buckets[.archived]?.items
      #expect(archived?[canonicalArchivedID]?.archivedAt == archivedAt)
    }
  }

  @Test(.dependencies) func writesEmptySidebarOnFreshInstall() throws {
    let storage = InMemorySettingsFileStorage()

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      // Migrator now stamps `Date.now` onto pre-#214 archived
      // straggler entries via `@Dependency(\.date.now)`; pin a
      // fixed instant here so the migration path doesn't trip the
      // "live dependency accessed from test" guard.
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      SidebarPersistenceMigrator.migrateIfNeeded(fileExists: { _ in false })

      let data = try storage.load(SupacodePaths.sidebarURL)
      let migrated = try JSONDecoder().decode(SidebarState.self, from: data)
      #expect(migrated.sections.isEmpty)
      #expect(migrated.focusedWorktreeID == nil)
    }
  }

  // MARK: - Remote-identity migration (schema v1 -> v2).

  @Test func stripLegacyIDPrefixesRemovesFolderAndRemoteMarkers() {
    #expect(SidebarPersistenceMigrator.stripLegacyIDPrefixes("/tmp/repo") == "/tmp/repo")
    #expect(SidebarPersistenceMigrator.stripLegacyIDPrefixes("remote://me@box/srv") == "me@box/srv")
    #expect(SidebarPersistenceMigrator.stripLegacyIDPrefixes("folder:/tmp/notes") == "/tmp/notes")
    // A folder-remote id collapses both retired markers in one pass.
    #expect(SidebarPersistenceMigrator.stripLegacyIDPrefixes("folder:remote://box/srv") == "box/srv")
  }

  @Test(.dependencies) func remoteIdentityMigrationDrainsLegacyConfigsAndRekeysIds() throws {
    let storage = InMemorySettingsFileStorage()
    // A schema-v1 sidebar carrying the retired prefixes: a remote git section and
    // a local folder row, plus a remote-keyed focus.
    var legacySidebar = SidebarState()
    legacySidebar.schemaVersion = 1
    legacySidebar.sections[RepositoryID("remote://me@box/srv/repo")] = SidebarState.Section(
      buckets: [.pinned: SidebarState.Bucket(items: [WorktreeID("remote://me@box/srv/repo"): .init()])]
    )
    legacySidebar.sections[RepositoryID("/tmp/notes")] = SidebarState.Section(
      buckets: [.unpinned: SidebarState.Bucket(items: [WorktreeID("folder:/tmp/notes"): .init()])]
    )
    legacySidebar.focusedWorktreeID = WorktreeID("folder:/tmp/notes")
    try storage.save(JSONEncoder().encode(legacySidebar), SupacodePaths.sidebarURL)

    // Raw legacy settings.json with the retired `global.remoteRepositories`. Fed to
    // the drain via `readFile` so a later settings save can't erase it mid-test.
    let legacySettings = Data(
      #"{"global":{"remoteRepositories":[{"host":{"alias":"box","username":"me"},"remotePath":"/srv/repo/"}]}}"#.utf8
    )

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock {
        $0.repositories = ["remote://me@box/srv/repo": .default]
        $0.pinnedWorktreeIDs = ["remote://me@box/srv/repo"]
      }
      let readFile: (URL) -> Data? = { url in
        url == SupacodePaths.settingsURL ? legacySettings : (try? storage.load(url))
      }
      let fileExists: (URL) -> Bool = { (try? storage.load($0)) != nil }

      let captured = SidebarPersistenceMigrator.captureLegacyRemoteRoots(
        fileExists: fileExists, readFile: readFile)
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: captured, fileExists: fileExists, readFile: readFile)

      // Legacy config drained into remoteRepositoryRoots (trailing slash normalized).
      @Shared(.remoteRepositoryRoots) var remoteRepositoryRoots
      #expect(remoteRepositoryRoots == ["me@box/srv/repo"])
      // Per-repo settings + pins re-keyed off the retired prefixes.
      #expect(settingsFile.repositories["me@box/srv/repo"] != nil)
      #expect(settingsFile.repositories["remote://me@box/srv/repo"] == nil)
      #expect(settingsFile.pinnedWorktreeIDs == ["me@box/srv/repo"])

      // sidebar.json re-keyed and stamped v2.
      let migrated = try JSONDecoder().decode(SidebarState.self, from: storage.load(SupacodePaths.sidebarURL))
      #expect(migrated.schemaVersion == 2)
      #expect(migrated.sections[RepositoryID("me@box/srv/repo")] != nil)
      #expect(migrated.sections[RepositoryID("remote://me@box/srv/repo")] == nil)
      #expect(
        migrated.sections[RepositoryID("me@box/srv/repo")]?.buckets[.pinned]?
          .items[WorktreeID("me@box/srv/repo")] != nil)
      #expect(
        migrated.sections[RepositoryID("/tmp/notes")]?.buckets[.unpinned]?
          .items[WorktreeID("/tmp/notes")] != nil)
      #expect(migrated.focusedWorktreeID == WorktreeID("/tmp/notes"))

      // Idempotent: a second pass is a no-op (the v2 gate short-circuits).
      let captured2 = SidebarPersistenceMigrator.captureLegacyRemoteRoots(
        fileExists: fileExists, readFile: readFile)
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: captured2, fileExists: fileExists, readFile: readFile)
      #expect(remoteRepositoryRoots == ["me@box/srv/repo"])
      let again = try JSONDecoder().decode(SidebarState.self, from: storage.load(SupacodePaths.sidebarURL))
      #expect(again.schemaVersion == 2)
      #expect(again.sections.count == 2)
    }
  }

  @Test(.dependencies) func remoteIdentityMigrationBailsWhenSidebarPresentButUnreadable() throws {
    let storage = InMemorySettingsFileStorage()
    var existing = SidebarState()
    existing.schemaVersion = 1
    existing.sections["/tmp/repo"] = SidebarState.Section(
      buckets: [.pinned: SidebarState.Bucket(items: ["/tmp/repo/wt": .init()])]
    )
    let existingBytes = try JSONEncoder().encode(existing)
    try storage.save(existingBytes, SupacodePaths.sidebarURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      // Present (fileExists true) but unreadable (readFile nil): must NOT overwrite
      // the layout with empty state, and must NOT stamp v2 (so it retries).
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: .none, fileExists: { _ in true }, readFile: { _ in nil })
      let after = try JSONDecoder().decode(SidebarState.self, from: storage.load(SupacodePaths.sidebarURL))
      #expect(after.schemaVersion == 1)
      #expect(after.sections["/tmp/repo"] != nil)
    }
  }

  @Test(.dependencies) func remoteIdentityMigrationAbortsWhenSettingsUnreadable() throws {
    let storage = InMemorySettingsFileStorage()
    var existing = SidebarState()
    existing.schemaVersion = 1
    try storage.save(try JSONEncoder().encode(existing), SupacodePaths.sidebarURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      // settings.json present but unreadable -> capture is `.unreadable`; the pass
      // must abort without stamping v2 so the legacy field survives to next launch.
      let captured = SidebarPersistenceMigrator.captureLegacyRemoteRoots(
        fileExists: { _ in true }, readFile: { _ in nil })
      #expect(captured == .unreadable)
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: captured, fileExists: { _ in true }, readFile: { try? storage.load($0) })
      let after = try JSONDecoder().decode(SidebarState.self, from: storage.load(SupacodePaths.sidebarURL))
      #expect(after.schemaVersion == 1)
    }
  }

  @Test(.dependencies) func remoteIdentityMigrationKeepsFirstOnKeyCollision() throws {
    let storage = InMemorySettingsFileStorage()
    // Both a retired `remote://X` section and a bare `X` section exist; after the
    // prefix strip they collide and the first-seen entry must win (no trap, no dupe).
    var legacy = SidebarState()
    legacy.schemaVersion = 1
    legacy.sections["remote://me@box/srv/repo"] = SidebarState.Section(
      buckets: [.pinned: SidebarState.Bucket(items: ["remote://me@box/srv/repo": .init(title: "first")])]
    )
    legacy.sections["me@box/srv/repo"] = SidebarState.Section(
      buckets: [.unpinned: SidebarState.Bucket(items: ["me@box/srv/repo": .init(title: "second")])]
    )
    try storage.save(try JSONEncoder().encode(legacy), SupacodePaths.sidebarURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: .none, fileExists: { (try? storage.load($0)) != nil }, readFile: { try? storage.load($0) })
      let migrated = try JSONDecoder().decode(SidebarState.self, from: storage.load(SupacodePaths.sidebarURL))
      #expect(migrated.sections.count == 1)
      #expect(migrated.sections["me@box/srv/repo"]?.buckets[.pinned]?.items["me@box/srv/repo"]?.title == "first")
    }
  }

  @Test(.dependencies) func remoteIdentityMigrationRekeysTerminalLayouts() throws {
    let storage = InMemorySettingsFileStorage()
    var sidebar = SidebarState()
    sidebar.schemaVersion = 1
    try storage.save(try JSONEncoder().encode(sidebar), SupacodePaths.sidebarURL)
    // Terminal layouts keyed by the retired worktree-id prefixes must follow the
    // ids, or remote/folder tabs won't restore after upgrade.
    let snapshot = TerminalLayoutSnapshot(tabs: [], selectedTabIndex: 0)
    let layouts: [String: TerminalLayoutSnapshot] = [
      "remote://me@box/srv/repo": snapshot,
      "folder:/tmp/notes": snapshot,
      "/tmp/local/wt": snapshot,
    ]
    try storage.save(try JSONEncoder().encode(layouts), SupacodePaths.layoutsURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: .none, fileExists: { (try? storage.load($0)) != nil }, readFile: { try? storage.load($0) })
      let migrated = try JSONDecoder().decode(
        [String: TerminalLayoutSnapshot].self, from: storage.load(SupacodePaths.layoutsURL))
      #expect(migrated["me@box/srv/repo"] != nil)
      #expect(migrated["/tmp/notes"] != nil)
      #expect(migrated["/tmp/local/wt"] != nil)
      #expect(migrated["remote://me@box/srv/repo"] == nil)
      #expect(migrated["folder:/tmp/notes"] == nil)
    }
  }

  @Test(.dependencies) func backupSnapshotsSettingsAndSidebarBeforeMigrating() throws {
    let storage = InMemorySettingsFileStorage()
    let settingsData = Data(#"{"global":{"remoteRepositories":[]},"repositoryRoots":["/tmp/repo"]}"#.utf8)
    try storage.save(settingsData, SupacodePaths.settingsURL)
    var sidebar = SidebarState()
    sidebar.schemaVersion = 1
    let sidebarData = try JSONEncoder().encode(sidebar)
    try storage.save(sidebarData, SupacodePaths.sidebarURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
    } operation: {
      SidebarPersistenceMigrator.backupBeforeRemoteIdentityMigration(
        fileExists: { (try? storage.load($0)) != nil }, readFile: { try? storage.load($0) })
      let suffix = SidebarPersistenceMigrator.preMigrationBackupSuffix
      let settingsBak = SupacodePaths.settingsURL.deletingLastPathComponent()
        .appendingPathComponent(SupacodePaths.settingsURL.lastPathComponent + suffix)
      let sidebarBak = SupacodePaths.sidebarURL.deletingLastPathComponent()
        .appendingPathComponent(SupacodePaths.sidebarURL.lastPathComponent + suffix)
      #expect((try? storage.load(settingsBak)) == settingsData)
      #expect((try? storage.load(sidebarBak)) == sidebarData)
    }
  }

  @Test(.dependencies) func backupSkipsOnceMigrated() throws {
    let storage = InMemorySettingsFileStorage()
    try storage.save(Data("{}".utf8), SupacodePaths.settingsURL)
    var sidebar = SidebarState()
    sidebar.schemaVersion = 2
    try storage.save(try JSONEncoder().encode(sidebar), SupacodePaths.sidebarURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
    } operation: {
      SidebarPersistenceMigrator.backupBeforeRemoteIdentityMigration(
        fileExists: { (try? storage.load($0)) != nil }, readFile: { try? storage.load($0) })
      let settingsBak = SupacodePaths.settingsURL.deletingLastPathComponent()
        .appendingPathComponent(
          SupacodePaths.settingsURL.lastPathComponent + SidebarPersistenceMigrator.preMigrationBackupSuffix)
      #expect((try? storage.load(settingsBak)) == nil)
    }
  }

  @Test(.dependencies) func remoteIdentityMigrationDrainsRemotesEvenWhenSidebarUnreadable() throws {
    let storage = InMemorySettingsFileStorage()
    // Sidebar present but unreadable: the re-key bails, but the captured remotes
    // must still be drained to their new home, not discarded.
    try storage.save(Data("not json".utf8), SupacodePaths.sidebarURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(load: { try storage.load($0) }, save: { try storage.save($0, $1) })
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    } operation: {
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(
        capturedLegacy: .roots(["me@box/srv/repo"]),
        fileExists: { (try? storage.load($0)) != nil },
        readFile: { try? storage.load($0) })
      @Shared(.remoteRepositoryRoots) var remoteRepositoryRoots
      #expect(remoteRepositoryRoots == ["me@box/srv/repo"])
    }
  }
}
