import Dependencies
import Foundation

public nonisolated struct RepositoryLocalSettingsStorage: Sendable {
  public var load: @Sendable (URL) throws -> Data
  public var save: @Sendable (Data, URL) throws -> Void

  public init(
    load: @escaping @Sendable (URL) throws -> Data,
    save: @escaping @Sendable (Data, URL) throws -> Void
  ) {
    self.load = load
    self.save = save
  }
}

nonisolated enum RepositoryLocalSettingsStorageKey: DependencyKey {
  static var liveValue: RepositoryLocalSettingsStorage {
    RepositoryLocalSettingsStorage(
      load: { try Data(contentsOf: $0) },
      // Do not follow symlinks here: this writes `<repoRoot>/supacode.json`, whose
      // contents come from a possibly-untrusted cloned repository. A symlink there
      // could point at any user-writable file, so the atomic write must replace the
      // link in the repo rather than write through it (an arbitrary-overwrite path).
      save: { data, url in
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
      }
    )
  }

  static var previewValue: RepositoryLocalSettingsStorage { .inMemory() }
  static var testValue: RepositoryLocalSettingsStorage { .inMemory() }
}

extension DependencyValues {
  public nonisolated var repositoryLocalSettingsStorage: RepositoryLocalSettingsStorage {
    get { self[RepositoryLocalSettingsStorageKey.self] }
    set { self[RepositoryLocalSettingsStorageKey.self] = newValue }
  }
}

extension RepositoryLocalSettingsStorage {
  nonisolated static func inMemory() -> RepositoryLocalSettingsStorage {
    let storage = InMemoryRepositoryLocalSettingsStorage()
    return RepositoryLocalSettingsStorage(
      load: { try storage.load($0) },
      save: { try storage.save($0, $1) }
    )
  }
}

nonisolated extension RepositoryLocalSettingsStorage {
  /// Whether a read failed only because the repo owns no `supacode.json`, which is the
  /// norm and stays quiet. Every other failure (permissions, a stalled mount) silently
  /// downgrades the repo to global settings, so callers log those.
  ///
  /// `Data(contentsOf:)` reports an absent file as `.fileReadNoSuchFile`, not as the
  /// `.fileNoSuchFile` its name suggests. Both count.
  static func isMissingFile(_ error: any Error) -> Bool {
    let code = (error as? CocoaError)?.code
    return code == .fileReadNoSuchFile || code == .fileNoSuchFile
  }
}

nonisolated final class InMemoryRepositoryLocalSettingsStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      // Mirror real-disk semantics: `Data(contentsOf:)` reports an absent file as
      // `.fileReadNoSuchFile`, and callers classify on it.
      throw CocoaError(.fileReadNoSuchFile)
    }
    return data
  }

  func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }
}
