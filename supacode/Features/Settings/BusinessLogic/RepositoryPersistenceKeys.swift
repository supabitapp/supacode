import Foundation
import Sharing

nonisolated struct RepositoryRootsKeyID: Hashable, Sendable {}

nonisolated struct RepositoryRootsKey: SharedKey {
  var id: RepositoryRootsKeyID {
    RepositoryRootsKeyID()
  }

  func load(
    context _: LoadContext<[String]>,
    continuation: LoadContinuation<[String]>
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let roots = $settingsFile.withLock { settings in
      let normalized = RepositoryPathNormalizer.normalize(settings.repositoryRoots)
      if normalized != settings.repositoryRoots {
        settings.repositoryRoots = normalized
      }
      return normalized
    }
    continuation.resume(returning: roots)
  }

  func subscribe(
    context _: LoadContext<[String]>,
    subscriber _: SharedSubscriber<[String]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [String],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let normalized = RepositoryPathNormalizer.normalize(value)
    $settingsFile.withLock {
      $0.repositoryRoots = normalized
    }
    continuation.resume()
  }
}

nonisolated struct PinnedWorktreeIDsKeyID: Hashable, Sendable {}

nonisolated struct PinnedWorktreeIDsKey: SharedKey {
  var id: PinnedWorktreeIDsKeyID {
    PinnedWorktreeIDsKeyID()
  }

  func load(
    context _: LoadContext<[Worktree.ID]>,
    continuation: LoadContinuation<[Worktree.ID]>
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let ids = $settingsFile.withLock { settings in
      let normalized = RepositoryPathNormalizer.normalize(settings.pinnedWorktreeIDs)
      if normalized != settings.pinnedWorktreeIDs {
        settings.pinnedWorktreeIDs = normalized
      }
      return normalized
    }
    continuation.resume(returning: ids)
  }

  func subscribe(
    context _: LoadContext<[Worktree.ID]>,
    subscriber _: SharedSubscriber<[Worktree.ID]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [Worktree.ID],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let normalized = RepositoryPathNormalizer.normalize(value)
    $settingsFile.withLock {
      $0.pinnedWorktreeIDs = normalized
    }
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == RepositoryRootsKey.Default {
  static var repositoryRoots: Self {
    Self[RepositoryRootsKey(), default: []]
  }
}

nonisolated extension SharedReaderKey where Self == PinnedWorktreeIDsKey.Default {
  static var pinnedWorktreeIDs: Self {
    Self[PinnedWorktreeIDsKey(), default: []]
  }
}

nonisolated enum RepositoryPathNormalizer {
  static func normalize(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var normalized: [String] = []
    normalized.reserveCapacity(paths.count)
    for path in paths {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let resolved = URL(fileURLWithPath: trimmed)
        .standardizedFileURL
        .path(percentEncoded: false)
      if seen.insert(resolved).inserted {
        normalized.append(resolved)
      }
    }
    return normalized
  }

  static func normalizeDictionaryKeys(
    _ dictionary: [String: Date]
  ) -> [String: Date] {
    var normalized: [String: Date] = [:]
    normalized.reserveCapacity(dictionary.count)
    for (key, value) in dictionary {
      let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let resolved = URL(fileURLWithPath: trimmed)
        .standardizedFileURL
        .path(percentEncoded: false)
      // On collision, keep the more recent (greater) date.
      if let existing = normalized[resolved], existing > value {
        continue
      }
      normalized[resolved] = value
    }
    return normalized
  }
}
