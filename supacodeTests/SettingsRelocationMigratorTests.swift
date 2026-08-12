import Dependencies
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SettingsRelocationMigratorTests {
  // MARK: - seedSettingsFromLegacy.

  @Test(.dependencies) func seedSettingsFromLegacyWritesSplitStore() throws {
    let settingsStore = InMemorySettingsFileStorage()
    var legacy = SettingsFile.default
    legacy.global.appearanceMode = .dark
    legacy.repositoryRoots = ["/tmp/repo-a"]
    legacy.remoteRepositoryRoots = ["me@box/srv/repo"]
    legacy.repositories = ["/tmp/repo-a/": .default]
    legacy.pinnedWorktreeIDs = ["/tmp/repo-a/wt-1"]
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacySettingsURL: try JSONEncoder().encode(legacy)])

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try settingsStore.load($0) }, save: { try settingsStore.save($0, $1) })
      $0.defaultAppStorage = .inMemory
    } operation: {
      let problems = SettingsRelocationMigrator.seedSettingsFromLegacy(fileSystem: fileSystem.system)
      #expect(problems.isEmpty)

      // `config.json` is the raw `GlobalSettings`, no "global" wrapper.
      let configData = try settingsStore.load(SupacodePaths.configURL)
      let configObject = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
      #expect(configObject["global"] == nil)
      #expect(try JSONDecoder().decode(GlobalSettings.self, from: configData).appearanceMode == .dark)

      // `routes.json` carries the local / remote roots.
      let routes = try JSONDecoder().decode(
        RoutesFile.self, from: settingsStore.load(SupacodePaths.routesURL))
      #expect(routes.local == ["/tmp/repo-a"])
      #expect(routes.remote == ["me@box/srv/repo"])

      // `repos.json` is the per-repo settings map.
      let repositories = try JSONDecoder().decode(
        [String: RepositorySettings].self, from: settingsStore.load(SupacodePaths.reposURL))
      #expect(repositories["/tmp/repo-a/"] != nil)
    }
  }

  @Test(.dependencies) func seedSettingsFromLegacyIsNoOpWhenStoreComplete() throws {
    // Seed re-runs while any slice is missing OR undecodable, so a no-op needs all
    // three present AND valid. The fake FS shares one dict with `settingsFileStorage`.
    let config = try JSONEncoder().encode(GlobalSettings.default)
    let routes = try JSONEncoder().encode(RoutesFile())
    let repositories = try JSONEncoder().encode([String: RepositorySettings]())
    let fileSystem = FakeRelocationFS(files: [
      SupacodePaths.configURL: config,
      SupacodePaths.routesURL: routes,
      SupacodePaths.reposURL: repositories,
      SupacodePaths.legacySettingsURL: try JSONEncoder().encode(SettingsFile.default),
    ])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = SettingsRelocationMigrator.seedSettingsFromLegacy(fileSystem: fileSystem.system)
      // The store is already complete, so nothing is rewritten from the legacy file.
      #expect(fileSystem.data(at: SupacodePaths.configURL) == config)
      #expect(fileSystem.data(at: SupacodePaths.routesURL) == routes)
    }
  }

  // MARK: - finishSeeding + retireLegacyFiles.

  @Test(.dependencies) func finishSeedingAndRetireSeedsUserDefaultsMovesLegacyAndLeavesSymlink() throws {
    let defaults = UserDefaults.inMemory
    let settingsData = Data("legacy-settings".utf8)
    var sidebar = SidebarState()
    sidebar.schemaVersion = 3
    let sidebarData = try JSONEncoder().encode(sidebar)
    let layoutsData = try JSONEncoder().encode(LayoutsFile(worktrees: [:]))
    // Seed a valid split store so `settings.json` is retirable, plus the legacy
    // files. A symlinked layouts file must stay put even once its counterpart landed.
    let fileSystem = FakeRelocationFS(
      files: [
        SupacodePaths.configURL: try JSONEncoder().encode(GlobalSettings.default),
        SupacodePaths.routesURL: try JSONEncoder().encode(RoutesFile()),
        SupacodePaths.reposURL: try JSONEncoder().encode([String: RepositorySettings]()),
        SupacodePaths.legacySettingsURL: settingsData,
        SupacodePaths.legacySidebarURL: sidebarData,
        SupacodePaths.legacyLayoutsURL: layoutsData,
      ],
      symlinks: [SupacodePaths.legacyLayoutsURL])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      _ = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // UserDefaults sidebar seeded with the schemaVersion preserved.
    let seededSidebar = try JSONDecoder().decode(
      SidebarState.self, from: try #require(defaults.data(forKey: SidebarKey.storageKey)))
    #expect(seededSidebar.schemaVersion == 3)
    // UserDefaults layouts seeded from the legacy file.
    let seededLayouts = try JSONDecoder().decode(
      LayoutsFile.self, from: try #require(defaults.data(forKey: LayoutsFile.userDefaultsKey)))
    #expect(seededLayouts.schemaVersion == LayoutsFile.currentSchemaVersion)

    // Regular legacy files moved into `.backup`.
    let settingsBackup = SupacodePaths.backupDirectory.appending(
      path: "settings.json", directoryHint: .notDirectory)
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == nil)
    #expect(fileSystem.data(at: settingsBackup) == settingsData)
    #expect(fileSystem.data(at: SupacodePaths.legacySidebarURL) == nil)

    // A symlink is left in place; relocating it would dangle the user's dotfiles.
    #expect(fileSystem.data(at: SupacodePaths.legacyLayoutsURL) == layoutsData)
    let layoutsBackup = SupacodePaths.backupDirectory.appending(
      path: "layouts.json", directoryHint: .notDirectory)
    #expect(fileSystem.data(at: layoutsBackup) == nil)
  }

  @Test(.dependencies) func retireLeavesSettingsInPlaceUntilAllThreeCountersLanded() throws {
    // `settings.json` maps to config / routes / repositories; a missing one must
    // hold the legacy file in place so a partial seed never loses data.
    let settingsData = Data("legacy-settings".utf8)
    let fileSystem = FakeRelocationFS(files: [
      SupacodePaths.configURL: try JSONEncoder().encode(GlobalSettings.default),
      SupacodePaths.routesURL: try JSONEncoder().encode(RoutesFile()),
      // repos.json intentionally absent.
      SupacodePaths.legacySettingsURL: settingsData,
    ])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // Not all counterparts landed, so the legacy file survives for the next run.
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == settingsData)
    let settingsBackup = SupacodePaths.backupDirectory.appending(
      path: "settings.json", directoryHint: .notDirectory)
    #expect(fileSystem.data(at: settingsBackup) == nil)
  }

  @Test(.dependencies) func retireSweepsLooseBackupFiles() {
    let bakURL = SupacodePaths.baseDirectory.appending(path: "layouts.json.bak", directoryHint: .notDirectory)
    let corruptURL = SupacodePaths.baseDirectory.appending(
      path: "sidebar.json.corrupt-20240101", directoryHint: .notDirectory)
    let keepURL = SupacodePaths.baseDirectory.appending(path: "notes.txt", directoryHint: .notDirectory)
    let fileSystem = FakeRelocationFS(files: [
      bakURL: Data("bak".utf8),
      corruptURL: Data("corrupt".utf8),
      keepURL: Data("keep".utf8),
    ])

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage.inMemory()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // `.bak` / `.corrupt-` files swept into `.backup`; unrelated files untouched.
    #expect(fileSystem.data(at: bakURL) == nil)
    #expect(
      fileSystem.data(
        at: SupacodePaths.backupDirectory.appending(path: "layouts.json.bak", directoryHint: .notDirectory))
        == Data("bak".utf8))
    #expect(fileSystem.data(at: corruptURL) == nil)
    #expect(fileSystem.data(at: keepURL) == Data("keep".utf8))
  }

  @Test(.dependencies) func retireNeverOverwritesAnExistingBackupSnapshot() throws {
    let golden = Data("golden".utf8)
    let newer = Data("newer".utf8)
    let settingsBackup = SupacodePaths.backupDirectory.appending(
      path: "settings.json", directoryHint: .notDirectory)
    // Seed a valid split store so `settings.json` is retirable and the move is
    // attempted. The shared-dict storage makes the seeded config / routes /
    // repositories visible to the completion check.
    let fileSystem = FakeRelocationFS(files: [
      SupacodePaths.configURL: try JSONEncoder().encode(GlobalSettings.default),
      SupacodePaths.routesURL: try JSONEncoder().encode(RoutesFile()),
      SupacodePaths.reposURL: try JSONEncoder().encode([String: RepositorySettings]()),
      SupacodePaths.legacySettingsURL: newer,
      settingsBackup: golden,
    ])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // The golden snapshot survives, and the newer legacy file stays put rather
    // than clobbering it.
    #expect(fileSystem.data(at: settingsBackup) == golden)
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == newer)
  }

  @Test(.dependencies) func finishSeedingKeepsAValidUserDefaultsValueAndItsLegacyFile() throws {
    let defaults = UserDefaults.inMemory
    // A VALID pre-existing value is the app's own state and must be kept.
    var appSidebar = SidebarState()
    appSidebar.schemaVersion = 7
    let existingApp = try JSONEncoder().encode(appSidebar)
    defaults.set(existingApp, forKey: SidebarKey.storageKey)
    let legacyData = try JSONEncoder().encode(SidebarState())
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacySidebarURL: legacyData])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      _ = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
      // The valid existing value is never re-seeded from the legacy file.
      #expect(defaults.data(forKey: SidebarKey.storageKey) == existingApp)
      // And because it wasn't seeded from the legacy file this run, that file is
      // preserved rather than retired (the key could be one the app wrote).
      #expect(fileSystem.data(at: SupacodePaths.legacySidebarURL) == legacyData)
    }
  }

  @Test(.dependencies) func finishSeedingReseedsAnInvalidUserDefaultsValueAndStashesIt() throws {
    let defaults = UserDefaults.inMemory
    // A present-but-corrupt value must not count as seeded: re-seed from the
    // legacy file and preserve the bad value under a recovery key.
    let corrupt = Data("not a sidebar".utf8)
    defaults.set(corrupt, forKey: SidebarKey.storageKey)
    var legacySidebar = SidebarState()
    legacySidebar.schemaVersion = 3
    let legacyData = try JSONEncoder().encode(legacySidebar)
    let fileSystem = FakeRelocationFS(files: [SupacodePaths.legacySidebarURL: legacyData])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      _ = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // The legacy sidebar is now seeded, the corrupt value preserved aside, and the
    // legacy file retired.
    let seeded = try JSONDecoder().decode(
      SidebarState.self, from: try #require(defaults.data(forKey: SidebarKey.storageKey)))
    #expect(seeded.schemaVersion == 3)
    #expect(defaults.data(forKey: SidebarKey.storageKey + ".corrupt") == corrupt)
    #expect(fileSystem.data(at: SupacodePaths.legacySidebarURL) == nil)
  }

  @Test(.dependencies) func finishSeedingPreservesSectionAndItemCustomization() throws {
    // The seed decodes the legacy `sidebar.json` and re-encodes it into UserDefaults.
    // A lossy round-trip would silently drop the user's repo titles / colors and
    // worktree titles, so assert every customization field survives, not just the
    // schema version.
    let defaults = UserDefaults.inMemory
    let repoID = RepositoryID("/tmp/repo-a/")
    let worktreeID = WorktreeID("/tmp/repo-a/wt-1")
    var section = SidebarState.Section()
    section.title = "olympus"
    section.color = .custom("#63C096")
    section.buckets[.unpinned] = SidebarState.Bucket(
      items: [worktreeID: SidebarState.Item(title: "my-worktree", color: .teal)])
    var sidebar = SidebarState(schemaVersion: 3)
    sidebar.sections[repoID] = section
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacySidebarURL: try JSONEncoder().encode(sidebar)])

    try withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      _ = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)

      let seeded = try JSONDecoder().decode(
        SidebarState.self, from: try #require(defaults.data(forKey: SidebarKey.storageKey)))
      let seededSection = try #require(seeded.sections[repoID])
      #expect(seededSection.title == "olympus")
      #expect(seededSection.color == .custom("#63C096"))
      #expect(seededSection.buckets[.unpinned]?.items[worktreeID]?.title == "my-worktree")
      #expect(seededSection.buckets[.unpinned]?.items[worktreeID]?.color == .teal)
    }
  }

  @Test(.dependencies) func corruptLegacySidebarIsNotSeededAndPreserved() throws {
    let defaults = UserDefaults.inMemory
    let garbage = Data("not a sidebar".utf8)
    let fileSystem = FakeRelocationFS(files: [SupacodePaths.legacySidebarURL: garbage])

    let problems: [String] = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      let problems = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
      return problems
    }

    // An undecodable sidebar is reported, never seeded, and left untouched so it
    // can be recovered by hand.
    #expect(problems.contains { $0.contains("sidebar") })
    #expect(defaults.data(forKey: SidebarKey.storageKey) == nil)
    #expect(fileSystem.data(at: SupacodePaths.legacySidebarURL) == garbage)
    let sidebarBackup = SupacodePaths.backupDirectory.appending(
      path: "sidebar.json", directoryHint: .notDirectory)
    #expect(fileSystem.data(at: sidebarBackup) == nil)
  }

  @Test(.dependencies) func finishSeedingStaysPendingWhenALegacyStoreIsUnreadable() throws {
    // A legacy sidebar that exists but can't be read is a transient I/O failure:
    // completion must be withheld so the migration retries, not stranded.
    let fileSystem = FakeRelocationFS(unreadable: [SupacodePaths.legacySidebarURL])

    let problems: [String] = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
    }

    #expect(problems.contains { $0.contains("sidebar") && $0.contains("retry") })
    // The marker is withheld, so a later launch retries.
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) == nil)
  }

  @Test(.dependencies) func pendingNoticeIsSurfacedOnceThenRetriesSilently() {
    let defaults = UserDefaults.inMemory
    let fileSystem = FakeRelocationFS(unreadable: [SupacodePaths.legacySidebarURL])

    let first: [String] = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
    }
    #expect(first.contains { $0.contains("sidebar") })

    let second: [String] = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
    }
    // Still pending (marker withheld) but no repeated alert on the second launch.
    #expect(second.isEmpty)
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) == nil)
  }

  // MARK: - Ghostty relocation.

  @Test(.dependencies) func relocatesGhosttyConfigAndRetiresLegacy() {
    let ghosttyContent = Data("font-size = 14\n".utf8)
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacyGhosttyUserConfigURL: ghosttyContent])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // The config lands at the new `config.ghostty` path via `writeData`.
    #expect(fileSystem.data(at: SupacodePaths.ghosttyUserConfigURL) == ghosttyContent)
    // The legacy file is retired into `.backup` once its counterpart landed.
    #expect(fileSystem.data(at: SupacodePaths.legacyGhosttyUserConfigURL) == nil)
    let ghosttyBackup = SupacodePaths.backupDirectory.appending(
      path: "ghostty.config", directoryHint: .notDirectory)
    #expect(fileSystem.data(at: ghosttyBackup) == ghosttyContent)
  }

  @Test(.dependencies) func finishSeedingStaysPendingWhenGhosttyWriteFails() {
    // A Ghostty write failure must not be sealed behind the marker: it retries.
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacyGhosttyUserConfigURL: Data("font-size = 14\n".utf8)],
      failingWrites: [SupacodePaths.ghosttyUserConfigURL])

    let problems: [String] = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
    }

    #expect(problems.contains { $0.contains("Ghostty") })
    // The destination never landed and the marker is withheld, so it retries.
    #expect(fileSystem.data(at: SupacodePaths.ghosttyUserConfigURL) == nil)
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) == nil)
    // The legacy config is preserved for the retry.
    #expect(fileSystem.data(at: SupacodePaths.legacyGhosttyUserConfigURL) != nil)
  }

  @Test(.dependencies) func skipsGhosttyRelocationWhenDestinationExists() {
    let existing = Data("existing-user-config\n".utf8)
    let legacy = Data("legacy-config\n".utf8)
    let fileSystem = FakeRelocationFS(files: [
      SupacodePaths.ghosttyUserConfigURL: existing,
      SupacodePaths.legacyGhosttyUserConfigURL: legacy,
    ])

    withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = SettingsRelocationMigrator.finishSeeding(fileSystem: fileSystem.system)
      SettingsRelocationMigrator.retireLegacyFiles(fileSystem: fileSystem.system)
    }

    // The existing destination is never clobbered by the legacy content.
    #expect(fileSystem.data(at: SupacodePaths.ghosttyUserConfigURL) == existing)
  }

  // MARK: - run outcomes.

  @Test(.dependencies) func runReturnsNoLegacyDataOnEmptyFileSystem() {
    let fileSystem = FakeRelocationFS()
    let outcome = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }
    #expect(outcome == .noLegacyData)
  }

  @Test(.dependencies) func runReturnsCompletedOnCleanLegacyBlob() throws {
    var legacy = SettingsFile.default
    legacy.global.appearanceMode = .dark
    legacy.repositoryRoots = ["/tmp/repo-a"]
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacySettingsURL: try JSONEncoder().encode(legacy)])

    let outcome = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }

    #expect(outcome == .completed)
    // The durable marker is stamped and the seeded split store exists.
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.configURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.routesURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.reposURL) != nil)
    // With all three counterparts landed, the legacy settings file is retired.
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == nil)
  }

  @Test(.dependencies) func runRunsLegacyMigratorsBeforeSeedingTheSplitStore() throws {
    var legacy = SettingsFile.default
    legacy.repositoryRoots = ["/tmp/repo-a"]
    let fileSystem = FakeRelocationFS(
      files: [SupacodePaths.legacySettingsURL: try JSONEncoder().encode(legacy)])
    var configPresentWhenMigratorsRan = true

    let outcome = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.run(
        fileSystem: fileSystem.system,
        legacyMigrators: {
          // config.json must not exist yet, so a sidebar migrator reading
          // @Shared(.settingsFile) still sees the legacy pins via the fallback.
          configPresentWhenMigratorsRan = fileSystem.data(at: SupacodePaths.configURL) != nil
        })
    }

    #expect(configPresentWhenMigratorsRan == false)
    #expect(outcome == .completed)
    // The seed still writes the split store afterward.
    #expect(fileSystem.data(at: SupacodePaths.configURL) != nil)
  }

  @Test(.dependencies) func runReturnsPendingWhenAWriteFailsAndKeepsTheOtherFilesAndSource() throws {
    var legacy = SettingsFile.default
    legacy.global.appearanceMode = .dark
    let legacyData = try JSONEncoder().encode(legacy)
    let fileSystem = FakeRelocationFS(files: [SupacodePaths.legacySettingsURL: legacyData])

    let outcome = withDependencies {
      // The repositories write fails; config / routes must still land.
      $0.settingsFileStorage = fileSystem.settingsStorage(failingSaves: [SupacodePaths.reposURL])
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }

    guard case .pending(let problems) = outcome else {
      Issue.record("Expected .pending, got \(outcome).")
      return
    }
    #expect(!problems.isEmpty)
    // One failure never aborts the rest: config / routes were still written.
    #expect(fileSystem.data(at: SupacodePaths.configURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.routesURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.reposURL) == nil)
    // The counterpart never landed, so the legacy settings file is NOT retired.
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == legacyData)
    // The migration is not marked complete, so it will retry.
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) == nil)
  }

  @Test(.dependencies) func runRetriesAfterAFailedSettingsWriteThenCompletes() throws {
    var legacy = SettingsFile.default
    legacy.repositoryRoots = ["/tmp/repo-a"]
    let legacyData = try JSONEncoder().encode(legacy)
    let fileSystem = FakeRelocationFS(files: [SupacodePaths.legacySettingsURL: legacyData])

    // First run: the repositories write fails, so the store is incomplete.
    let first = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage(failingSaves: [SupacodePaths.reposURL])
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }
    guard case .pending = first else {
      Issue.record("Expected .pending on the failed write, got \(first).")
      return
    }
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) == nil)
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == legacyData)

    // Second run with working storage re-seeds the missing slice and completes.
    let second = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = .inMemory
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }
    #expect(second == .completed)
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == nil)
  }

  @Test(.dependencies) func runTwiceResumesWithoutRefabricating() throws {
    let defaults = UserDefaults.inMemory
    var legacy = SettingsFile.default
    legacy.global.appearanceMode = .dark
    let layoutsData = try JSONEncoder().encode(LayoutsFile(worktrees: [:]))
    // A symlinked legacy layouts file survives retirement, so `hasLegacyFiles`
    // stays true and the second run still exercises the marker gate.
    let fileSystem = FakeRelocationFS(
      files: [
        SupacodePaths.legacySettingsURL: try JSONEncoder().encode(legacy),
        SupacodePaths.legacyLayoutsURL: layoutsData,
      ],
      symlinks: [SupacodePaths.legacyLayoutsURL])

    let first = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }
    #expect(first == .completed)
    #expect(fileSystem.data(at: SupacodePaths.relocationMarkerURL) != nil)
    #expect(fileSystem.data(at: SupacodePaths.legacySettingsURL) == nil)

    // Clobber the seeded config; the marker must gate the seed so a resume never
    // re-fabricates it from the (now retired) legacy file.
    let sentinel = Data("sentinel".utf8)
    fileSystem.set(sentinel, at: SupacodePaths.configURL)

    let second = withDependencies {
      $0.settingsFileStorage = fileSystem.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      SettingsRelocationMigrator.run(fileSystem: fileSystem.system, legacyMigrators: {})
    }
    #expect(second == .completed)
    #expect(fileSystem.data(at: SupacodePaths.configURL) == sentinel)
  }
}

/// In-memory `RelocationFileSystem` so the migrator never touches the real
/// `~/.supacode`. Backs path ops with a `[URL: Data]` dict plus a symlink set. A
/// sibling `settingsStorage()` shares the same dict, so files the seed writes
/// through `\.settingsFileStorage` are visible to the FS existence checks.
private nonisolated final class FakeRelocationFS: @unchecked Sendable {
  private let lock = NSLock()
  private var files: [URL: Data]
  private let symlinks: Set<URL>
  /// Paths that exist but fail to read, simulating a transient I/O failure.
  private let unreadable: Set<URL>
  /// Paths whose `writeData` throws, simulating a write failure.
  private let failingWrites: Set<URL>

  init(
    files: [URL: Data] = [:],
    symlinks: Set<URL> = [],
    unreadable: Set<URL> = [],
    failingWrites: Set<URL> = []
  ) {
    self.files = files
    self.symlinks = symlinks
    self.unreadable = unreadable
    self.failingWrites = failingWrites
  }

  func data(at url: URL) -> Data? {
    withLock { files[url] }
  }

  func set(_ data: Data?, at url: URL) {
    withLock { files[url] = data }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  var system: RelocationFileSystem {
    RelocationFileSystem(
      fileExists: { url in self.unreadable.contains(url) || self.withLock { self.files[url] != nil } },
      readData: { url in self.unreadable.contains(url) ? nil : self.withLock { self.files[url] } },
      writeData: { data, url in
        guard !self.failingWrites.contains(url) else { throw CocoaError(.fileWriteUnknown) }
        self.withLock { self.files[url] = data }
      },
      isSymbolicLink: { url in self.symlinks.contains(url) },
      moveItem: { source, destination in
        try self.withLock {
          guard let data = self.files[source] else { throw CocoaError(.fileNoSuchFile) }
          self.files[destination] = data
          self.files[source] = nil
        }
      },
      createDirectory: { _ in },
      contentsOfDirectory: { directory in
        let directoryPath = directory.standardizedFileURL.path(percentEncoded: false)
        return self.withLock {
          var entries: [URL] = []
          for url in self.files.keys
          where url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            == directoryPath
          {
            entries.append(url)
          }
          return entries
        }
      }
    )
  }

  /// Settings store backed by the same dict. `failingSaves` throws for the given
  /// URLs so a single-file write failure is testable.
  func settingsStorage(failingSaves: Set<URL> = []) -> SettingsFileStorage {
    SettingsFileStorage(
      load: { url in
        try self.withLock {
          guard let data = self.files[url] else { throw CocoaError(.fileReadNoSuchFile) }
          return data
        }
      },
      save: { data, url in
        guard !failingSaves.contains(url) else { throw CocoaError(.fileWriteUnknown) }
        self.withLock { self.files[url] = data }
      }
    )
  }
}
