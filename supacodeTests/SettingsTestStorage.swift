import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated final class SettingsTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]
  private var writes = 0
  private var reads = 0

  /// Disk writes performed so far. A pure settings *read* must leave this at zero.
  var saveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return writes
  }

  var loadCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  func resetCounts() {
    lock.lock()
    defer { lock.unlock() }
    writes = 0
    reads = 0
  }

  var storage: SettingsFileStorage {
    SettingsFileStorage(
      load: { try self.load($0) },
      save: { try self.save($0, $1) }
    )
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    reads += 1
    guard let data = dataByURL[url] else {
      throw SettingsTestStorageError.missing
    }
    return data
  }

  private func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    writes += 1
    dataByURL[url] = data
  }
}

enum SettingsTestStorageError: Error {
  case missing
}
