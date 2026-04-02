import ComposableArchitecture
import Foundation
import Sharing

nonisolated let archivedWorktreeDatesStorageKey = "archivedWorktreeDates"
nonisolated let secondsPerDay: TimeInterval = 86400

struct RepositoryPersistenceClient {
  var loadRoots: @Sendable () async -> [String]
  var saveRoots: @Sendable ([String]) async -> Void
  var loadPinnedWorktreeIDs: @Sendable () async -> [Worktree.ID]
  var savePinnedWorktreeIDs: @Sendable ([Worktree.ID]) async -> Void
  var loadArchivedWorktreeDates: @Sendable () async -> [Worktree.ID: Date]
  var saveArchivedWorktreeDates: @Sendable ([Worktree.ID: Date]) async -> Void
  var loadRepositoryOrderIDs: @Sendable () async -> [Repository.ID]
  var saveRepositoryOrderIDs: @Sendable ([Repository.ID]) async -> Void
  var loadWorktreeOrderByRepository: @Sendable () async -> [Repository.ID: [Worktree.ID]]
  var saveWorktreeOrderByRepository: @Sendable ([Repository.ID: [Worktree.ID]]) async -> Void
  var loadLastFocusedWorktreeID: @Sendable () async -> Worktree.ID?
  var saveLastFocusedWorktreeID: @Sendable (Worktree.ID?) async -> Void
}

extension RepositoryPersistenceClient: DependencyKey {
  static let liveValue: RepositoryPersistenceClient = {
    return RepositoryPersistenceClient(
      loadRoots: {
        @Shared(.repositoryRoots) var roots: [String]
        return roots
      },
      saveRoots: { roots in
        @Shared(.repositoryRoots) var sharedRoots: [String]
        $sharedRoots.withLock {
          $0 = roots
        }
      },
      loadPinnedWorktreeIDs: {
        @Shared(.pinnedWorktreeIDs) var pinned: [Worktree.ID]
        return pinned
      },
      savePinnedWorktreeIDs: { ids in
        @Shared(.pinnedWorktreeIDs) var sharedPinned: [Worktree.ID]
        $sharedPinned.withLock {
          $0 = ids
        }
      },
      loadArchivedWorktreeDates: {
        let logger = SupaLogger("RepositoryPersistence")
        @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var dates: [Worktree.ID: Date] = [:]
        guard dates.isEmpty else {
          return RepositoryPathNormalizer.normalizeDictionaryKeys(dates)
        }
        // Migrate from legacy key.
        @Shared(.appStorage("archivedWorktreeIDs")) var legacyIDs: [Worktree.ID] = []
        guard !legacyIDs.isEmpty else { return [:] }
        let now = Date()
        var migrated: [Worktree.ID: Date] = [:]
        for id in RepositoryPathNormalizer.normalize(legacyIDs) {
          migrated[id] = now
        }
        logger.info("Migrating \(migrated.count) archived worktree(s) from legacy key.")
        $dates.withLock { $0 = migrated }
        $legacyIDs.withLock { $0 = [] }
        return migrated
      },
      saveArchivedWorktreeDates: { dates in
        @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var sharedDates: [Worktree.ID: Date] = [:]
        let normalized = RepositoryPathNormalizer.normalizeDictionaryKeys(dates)
        $sharedDates.withLock {
          $0 = normalized
        }
      },
      loadRepositoryOrderIDs: {
        @Shared(.appStorage("repositoryOrderIDs")) var order: [Repository.ID] = []
        return RepositoryOrderNormalizer.normalizeRepositoryIDs(order)
      },
      saveRepositoryOrderIDs: { ids in
        @Shared(.appStorage("repositoryOrderIDs")) var sharedOrder: [Repository.ID] = []
        let normalized = RepositoryOrderNormalizer.normalizeRepositoryIDs(ids)
        $sharedOrder.withLock {
          $0 = normalized
        }
      },
      loadWorktreeOrderByRepository: {
        @Shared(.appStorage("worktreeOrderByRepository")) var order: [Repository.ID: [Worktree.ID]] = [:]
        return RepositoryOrderNormalizer.normalizeWorktreeOrderByRepository(order)
      },
      saveWorktreeOrderByRepository: { order in
        @Shared(.appStorage("worktreeOrderByRepository")) var sharedOrder: [Repository.ID: [Worktree.ID]] = [:]
        let normalized = RepositoryOrderNormalizer.normalizeWorktreeOrderByRepository(order)
        $sharedOrder.withLock {
          $0 = normalized
        }
      },
      loadLastFocusedWorktreeID: {
        @Shared(.appStorage("lastFocusedWorktreeID")) var lastFocused: Worktree.ID?
        return lastFocused
      },
      saveLastFocusedWorktreeID: { id in
        @Shared(.appStorage("lastFocusedWorktreeID")) var sharedLastFocused: Worktree.ID?
        $sharedLastFocused.withLock {
          $0 = id
        }
      }
    )
  }()
  static let testValue = RepositoryPersistenceClient(
    loadRoots: { [] },
    saveRoots: { _ in },
    loadPinnedWorktreeIDs: { [] },
    savePinnedWorktreeIDs: { _ in },
    loadArchivedWorktreeDates: { [:] },
    saveArchivedWorktreeDates: { _ in },
    loadRepositoryOrderIDs: { [] },
    saveRepositoryOrderIDs: { _ in },
    loadWorktreeOrderByRepository: { [:] },
    saveWorktreeOrderByRepository: { _ in },
    loadLastFocusedWorktreeID: { nil },
    saveLastFocusedWorktreeID: { _ in }
  )
}

extension DependencyValues {
  var repositoryPersistence: RepositoryPersistenceClient {
    get { self[RepositoryPersistenceClient.self] }
    set { self[RepositoryPersistenceClient.self] = newValue }
  }
}

nonisolated enum RepositoryOrderNormalizer {
  static func normalizeRepositoryIDs(_ ids: [Repository.ID]) -> [Repository.ID] {
    RepositoryPathNormalizer.normalize(ids)
  }

  static func normalizeWorktreeOrderByRepository(
    _ order: [Repository.ID: [Worktree.ID]]
  ) -> [Repository.ID: [Worktree.ID]] {
    var normalized: [Repository.ID: [Worktree.ID]] = [:]
    for (repoID, worktreeIDs) in order {
      guard let normalizedRepoID = normalizePath(repoID) else { continue }
      let normalizedWorktreeIDs = RepositoryPathNormalizer.normalize(worktreeIDs)
      guard !normalizedWorktreeIDs.isEmpty else { continue }
      if var existing = normalized[normalizedRepoID] {
        for id in normalizedWorktreeIDs where !existing.contains(id) {
          existing.append(id)
        }
        normalized[normalizedRepoID] = existing
      } else {
        normalized[normalizedRepoID] = normalizedWorktreeIDs
      }
    }
    return normalized
  }

  private static func normalizePath(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed)
      .standardizedFileURL
      .path(percentEncoded: false)
  }
}
