import Foundation

@testable import SupacodeSettingsShared
@testable import supacode

nonisolated final class RepositoryLocalSettingsTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]
  private var writes = 0
  private var reads = 0

  /// Writes routed through `storage`, i.e. production saves. Test seeding via
  /// `save(_:at:)` is excluded so a pure read can assert this stays at zero.
  var saveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return writes
  }

  /// Reads routed through `storage`. Every resolution of a repository's settings
  /// probes the local `supacode.json` first, so this counts settings resolutions.
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

  var storage: RepositoryLocalSettingsStorage {
    RepositoryLocalSettingsStorage(
      load: { try self.load($0) },
      save: { data, url in
        self.lock.lock()
        self.writes += 1
        self.lock.unlock()
        try self.save(data, at: url)
      }
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
    reads += 1
    guard let data = dataByURL[url] else {
      // Mirror real-disk semantics: `Data(contentsOf:)` reports an absent file as
      // `.fileReadNoSuchFile`, and callers classify on it.
      throw CocoaError(.fileReadNoSuchFile)
    }
    return data
  }
}
