import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
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

  // MARK: - Roots

  @Test(.dependencies) func savesAndLoadsRoots() async throws {
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
    let roots = await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      await client.saveRoots([
        "/tmp/repo-a",
        "/tmp/repo-a",
        "/tmp/repo-b/../repo-b",
      ])
      return await client.loadRoots()
    }

    #expect(roots == ["/tmp/repo-a", "/tmp/repo-b"])

    let finalSettings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(finalSettings.global.appearanceMode == .dark)
  }
}
