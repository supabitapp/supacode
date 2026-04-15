import ComposableArchitecture
import Foundation
import Sharing

public nonisolated let archivedWorktreeDatesStorageKey = "archivedWorktreeDates"
public nonisolated let secondsPerDay: TimeInterval = 86400

public nonisolated struct ArchivedWorktreeDatesClient: Sendable {
  public var load: @Sendable () async -> [String: Date]
  public var save: @Sendable ([String: Date]) async -> Void

  public init(
    load: @escaping @Sendable () async -> [String: Date],
    save: @escaping @Sendable ([String: Date]) async -> Void
  ) {
    self.load = load
    self.save = save
  }
}

extension ArchivedWorktreeDatesClient: DependencyKey {
  public static let liveValue = ArchivedWorktreeDatesClient(
    load: {
      let logger = SupaLogger("ArchivedWorktreeDates")
      @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var dates: [String: Date] = [:]
      let normalizedDates = RepositoryPathNormalizer.normalizeDictionaryKeys(dates)
      if normalizedDates != dates {
        $dates.withLock { $0 = normalizedDates }
      }
      guard normalizedDates.isEmpty else {
        return normalizedDates
      }
      @Shared(.appStorage("archivedWorktreeIDs")) var legacyIDs: [String] = []
      let normalizedLegacyIDs = RepositoryPathNormalizer.normalize(legacyIDs)
      guard !normalizedLegacyIDs.isEmpty else {
        return [:]
      }
      let now = Date()
      let migrated = Dictionary(uniqueKeysWithValues: normalizedLegacyIDs.map { ($0, now) })
      logger.info("Migrating \(migrated.count) archived worktree(s) from legacy key.")
      $dates.withLock { $0 = migrated }
      $legacyIDs.withLock { $0 = [] }
      return migrated
    },
    save: { dates in
      @Shared(.appStorage(archivedWorktreeDatesStorageKey)) var sharedDates: [String: Date] = [:]
      let normalizedDates = RepositoryPathNormalizer.normalizeDictionaryKeys(dates)
      $sharedDates.withLock { $0 = normalizedDates }
    }
  )

  public static let testValue = ArchivedWorktreeDatesClient(
    load: { [:] },
    save: { _ in }
  )
}

public extension DependencyValues {
  var archivedWorktreeDatesClient: ArchivedWorktreeDatesClient {
    get { self[ArchivedWorktreeDatesClient.self] }
    set { self[ArchivedWorktreeDatesClient.self] = newValue }
  }
}
