import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated final class RepositoryLocalSettingsTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  var storage: RepositoryLocalSettingsStorage {
    RepositoryLocalSettingsStorage(
      load: { try self.load($0) },
      save: { try self.save($0, at: $1) }
    )
  }

  func data(at url: URL) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return dataByURL[url]
  }

  func save(_ data: Data, at url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      throw RepositoryLocalSettingsStorageError.missing
    }
    return data
  }
}
