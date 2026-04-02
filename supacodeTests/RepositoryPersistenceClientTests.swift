import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct RepositoryPersistenceClientTests {
  // MARK: - normalizeDictionaryKeys

  @Test func normalizeDictionaryKeysResolvesPaths() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let result = RepositoryPathNormalizer.normalizeDictionaryKeys([
      "/tmp/repo/../repo/feature": date
    ])
    #expect(result == ["/tmp/repo/feature": date])
  }

  @Test func normalizeDictionaryKeysDropsEmptyKeys() {
    let date = Date(timeIntervalSince1970: 1_000_000)
    let result = RepositoryPathNormalizer.normalizeDictionaryKeys([
      "": date,
      "  ": date,
      "/tmp/repo/feature": date,
    ])
    #expect(result.count == 1)
    #expect(result["/tmp/repo/feature"] == date)
  }

  @Test func normalizeDictionaryKeysKeepsMoreRecentDateOnCollision() {
    let older = Date(timeIntervalSince1970: 1_000_000)
    let newer = Date(timeIntervalSince1970: 2_000_000)
    let result = RepositoryPathNormalizer.normalizeDictionaryKeys([
      "/tmp/repo/feature": older,
      "/tmp/repo/../repo/feature": newer,
    ])
    #expect(result.count == 1)
    #expect(result["/tmp/repo/feature"] == newer)
  }

  @Test func normalizeDictionaryKeysReturnsEmptyForEmptyInput() {
    let result = RepositoryPathNormalizer.normalizeDictionaryKeys([:])
    #expect(result.isEmpty)
  }

  // MARK: - Legacy Migration

  @Test(.dependencies) func loadArchivedWorktreeDatesMigratesLegacyKey() async {
    let client = RepositoryPersistenceClient.liveValue
    @Shared(.appStorage("archivedWorktreeIDs")) var legacyIDs: [Worktree.ID] = []
    @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var dates: [Worktree.ID: Date] = [:]
    $legacyIDs.withLock { $0 = ["/tmp/repo/feature", "/tmp/repo/bugfix"] }
    $dates.withLock { $0 = [:] }

    let result = await client.loadArchivedWorktreeDates()
    #expect(result.count == 2)
    #expect(result["/tmp/repo/feature"] != nil)
    #expect(result["/tmp/repo/bugfix"] != nil)
    // Legacy key should be cleared after migration.
    #expect(legacyIDs.isEmpty)
  }

  // MARK: - Roots and Pins

  @Test(.dependencies) func savesAndLoadsRootsAndPins() async throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
      }
    }

    let client = RepositoryPersistenceClient.liveValue
    let result = await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      await client.saveRoots([
        "/tmp/repo-a",
        "/tmp/repo-a",
        "/tmp/repo-b/../repo-b",
      ])
      await client.savePinnedWorktreeIDs([
        "/tmp/repo-a/wt-1",
        "/tmp/repo-a/wt-1",
      ])
      let roots = await client.loadRoots()
      let pinned = await client.loadPinnedWorktreeIDs()
      return (roots: roots, pinned: pinned)
    }

    #expect(result.roots == ["/tmp/repo-a", "/tmp/repo-b"])
    #expect(result.pinned == ["/tmp/repo-a/wt-1"])

    let finalSettings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(finalSettings.global.appearanceMode == .dark)
  }
}
