import Foundation
import Sharing

public nonisolated struct RepositoryRootsKeyID: Hashable, Sendable {
  public init() {}
}

public nonisolated struct RepositoryRootsKey: SharedKey {
  public init() {}

  public var id: RepositoryRootsKeyID {
    RepositoryRootsKeyID()
  }

  public func load(
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

  public func subscribe(
    context _: LoadContext<[String]>,
    subscriber _: SharedSubscriber<[String]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(
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

public nonisolated struct PinnedWorktreeIDsKeyID: Hashable, Sendable {
  public init() {}
}

public nonisolated struct PinnedWorktreeIDsKey: SharedKey {
  public init() {}

  public var id: PinnedWorktreeIDsKeyID {
    PinnedWorktreeIDsKeyID()
  }

  public func load(
    context _: LoadContext<[String]>,
    continuation: LoadContinuation<[String]>
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

  public func subscribe(
    context _: LoadContext<[String]>,
    subscriber _: SharedSubscriber<[String]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(
    _ value: [String],
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
  public static var repositoryRoots: Self {
    Self[RepositoryRootsKey(), default: []]
  }
}

nonisolated extension SharedReaderKey where Self == PinnedWorktreeIDsKey.Default {
  public static var pinnedWorktreeIDs: Self {
    Self[PinnedWorktreeIDsKey(), default: []]
  }
}

public nonisolated enum RepositoryPathNormalizer {
  /// Canonical single-path normalisation. Returns `nil` for empty
  /// or whitespace-only inputs so callers can drop bogus entries
  /// without constructing a throwaway array first. Every
  /// repository / worktree identifier at rest goes through this
  /// codepath so string comparisons against live `Repository.ID`
  /// and `Worktree.ID` values stay consistent.
  public static func normalize(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed)
      .standardizedFileURL
      .path(percentEncoded: false)
  }

  public static func normalize(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var normalized: [String] = []
    normalized.reserveCapacity(paths.count)
    for path in paths {
      guard let resolved = normalize(path) else { continue }
      if seen.insert(resolved).inserted {
        normalized.append(resolved)
      }
    }
    return normalized
  }

  public static func normalizeDictionaryKeys(
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
