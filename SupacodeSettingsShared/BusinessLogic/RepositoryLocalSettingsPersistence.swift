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

nonisolated enum RepositoryLocalSettingsStorageError: Error {
  case missing
}

nonisolated final class InMemoryRepositoryLocalSettingsStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      throw RepositoryLocalSettingsStorageError.missing
    }
    return data
  }

  func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }
}
