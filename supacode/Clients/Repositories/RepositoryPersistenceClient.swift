import ComposableArchitecture
import Foundation
import Sharing

struct RepositoryPersistenceClient {
  var loadRoots: @Sendable () async -> [String]
  var saveRoots: @Sendable ([String]) async -> Void
  var loadPinnedWorktreeIDs: @Sendable () async -> [Worktree.ID]
  var savePinnedWorktreeIDs: @Sendable ([Worktree.ID]) async -> Void
  var loadArchivedWorktreeIDs: @Sendable () async -> [Worktree.ID]
  var saveArchivedWorktreeIDs: @Sendable ([Worktree.ID]) async -> Void
  var loadRepositoryOrderIDs: @Sendable () async -> [Repository.ID]
  var saveRepositoryOrderIDs: @Sendable ([Repository.ID]) async -> Void
  var loadWorktreeOrderByRepository: @Sendable () async -> [Repository.ID: [Worktree.ID]]
  var saveWorktreeOrderByRepository: @Sendable ([Repository.ID: [Worktree.ID]]) async -> Void
  var loadLastFocusedWorktreeID: @Sendable () async -> Worktree.ID?
  var saveLastFocusedWorktreeID: @Sendable (Worktree.ID?) async -> Void
  var loadTasks: @Sendable () async -> [CodingTask]
  var saveTasks: @Sendable ([CodingTask]) async -> Void
  var loadArchivedTaskIDs: @Sendable () async -> [CodingTask.ID]
  var saveArchivedTaskIDs: @Sendable ([CodingTask.ID]) async -> Void
  var loadTaskOrderByRepository: @Sendable () async -> [Repository.ID: [CodingTask.ID]]
  var saveTaskOrderByRepository: @Sendable ([Repository.ID: [CodingTask.ID]]) async -> Void
  var loadLastFocusedTaskID: @Sendable () async -> CodingTask.ID?
  var saveLastFocusedTaskID: @Sendable (CodingTask.ID?) async -> Void
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
      loadArchivedWorktreeIDs: {
        @Shared(.appStorage("archivedWorktreeIDs")) var archived: [Worktree.ID] = []
        return RepositoryPathNormalizer.normalize(archived)
      },
      saveArchivedWorktreeIDs: { ids in
        @Shared(.appStorage("archivedWorktreeIDs")) var sharedArchived: [Worktree.ID] = []
        let normalized = RepositoryPathNormalizer.normalize(ids)
        $sharedArchived.withLock {
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
      },
      loadTasks: {
        @Shared(.appStorage("codingTasks")) var tasks: Data?
        guard let data = tasks else { return [] }
        return (try? JSONDecoder().decode([CodingTask].self, from: data)) ?? []
      },
      saveTasks: { tasks in
        @Shared(.appStorage("codingTasks")) var sharedTasks: Data?
        let data = try? JSONEncoder().encode(tasks)
        $sharedTasks.withLock {
          $0 = data
        }
      },
      loadArchivedTaskIDs: {
        @Shared(.appStorage("archivedTaskIDs")) var archived: [CodingTask.ID] = []
        return archived
      },
      saveArchivedTaskIDs: { ids in
        @Shared(.appStorage("archivedTaskIDs")) var sharedArchived: [CodingTask.ID] = []
        $sharedArchived.withLock {
          $0 = ids
        }
      },
      loadTaskOrderByRepository: {
        @Shared(.appStorage("taskOrderByRepository")) var order: [Repository.ID: [CodingTask.ID]] = [:]
        return order
      },
      saveTaskOrderByRepository: { order in
        @Shared(.appStorage("taskOrderByRepository"))
        var sharedOrder: [Repository.ID: [CodingTask.ID]] = [:]
        $sharedOrder.withLock {
          $0 = order
        }
      },
      loadLastFocusedTaskID: {
        @Shared(.appStorage("lastFocusedTaskID")) var lastFocused: CodingTask.ID?
        return lastFocused
      },
      saveLastFocusedTaskID: { id in
        @Shared(.appStorage("lastFocusedTaskID")) var sharedLastFocused: CodingTask.ID?
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
    loadArchivedWorktreeIDs: { [] },
    saveArchivedWorktreeIDs: { _ in },
    loadRepositoryOrderIDs: { [] },
    saveRepositoryOrderIDs: { _ in },
    loadWorktreeOrderByRepository: { [:] },
    saveWorktreeOrderByRepository: { _ in },
    loadLastFocusedWorktreeID: { nil },
    saveLastFocusedWorktreeID: { _ in },
    loadTasks: { [] },
    saveTasks: { _ in },
    loadArchivedTaskIDs: { [] },
    saveArchivedTaskIDs: { _ in },
    loadTaskOrderByRepository: { [:] },
    saveTaskOrderByRepository: { _ in },
    loadLastFocusedTaskID: { nil },
    saveLastFocusedTaskID: { _ in }
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
