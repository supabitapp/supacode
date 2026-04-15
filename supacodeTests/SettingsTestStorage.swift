import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated final class SettingsTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  var storage: SettingsFileStorage {
    SettingsFileStorage(
      load: { try self.load($0) },
      save: { try self.save($0, $1) }
    )
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      throw SettingsTestStorageError.missing
    }
    return data
  }

  private func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }
}

enum SettingsTestStorageError: Error {
  case missing
}
