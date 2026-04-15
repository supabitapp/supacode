import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct ArchivedWorktreeDatesClientTests {
  @Test(.dependencies) func loadNormalizesStoredKeys() async {
    let suiteName = "ArchivedWorktreeDatesClientTests.load.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    store.removePersistentDomain(forName: suiteName)

    await withDependencies {
      $0.defaultAppStorage = store
    } operation: {
      let date = Date(timeIntervalSince1970: 1_000_000)
      @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var archivedDates: [String: Date] = [:]
      $archivedDates.withLock { $0 = ["/tmp/repo/../repo/feature": date] }

      let result = await ArchivedWorktreeDatesClient.liveValue.load()

      #expect(result == ["/tmp/repo/feature": date])
      #expect(archivedDates == ["/tmp/repo/feature": date])
    }
  }

  @Test(.dependencies) func loadMigratesLegacyIDs() async {
    let suiteName = "ArchivedWorktreeDatesClientTests.migrate.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    store.removePersistentDomain(forName: suiteName)

    await withDependencies {
      $0.defaultAppStorage = store
    } operation: {
      @Shared(.appStorage("archivedWorktreeIDs")) var legacyIDs: [String] = []
      @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var archivedDates: [String: Date] = [:]
      $legacyIDs.withLock { $0 = ["/tmp/repo/feature", "/tmp/repo/bugfix"] }
      $archivedDates.withLock { $0 = [:] }

      let result = await ArchivedWorktreeDatesClient.liveValue.load()

      #expect(result.count == 2)
      #expect(result["/tmp/repo/feature"] != nil)
      #expect(result["/tmp/repo/bugfix"] != nil)
      #expect(legacyIDs.isEmpty)
      #expect(archivedDates == result)
    }
  }

  @Test(.dependencies) func saveNormalizesKeys() async {
    let suiteName = "ArchivedWorktreeDatesClientTests.save.\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    store.removePersistentDomain(forName: suiteName)

    await withDependencies {
      $0.defaultAppStorage = store
    } operation: {
      let older = Date(timeIntervalSince1970: 1_000_000)
      let newer = Date(timeIntervalSince1970: 2_000_000)

      await ArchivedWorktreeDatesClient.liveValue.save([
        "/tmp/repo/feature": older,
        "/tmp/repo/../repo/feature": newer,
      ])

      @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var archivedDates: [String: Date] = [:]
      #expect(archivedDates == ["/tmp/repo/feature": newer])
    }
  }
}
