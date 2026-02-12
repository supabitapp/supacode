import Dependencies
import Foundation

nonisolated struct SupacodeHomeOverridePersistence: Sendable {
  var load: @Sendable () -> String?
  var save: @Sendable (String?) -> Void
}

nonisolated enum SupacodeHomeOverridePersistenceKey: DependencyKey {
  static var liveValue: SupacodeHomeOverridePersistence {
    SupacodeHomeOverridePersistence(
      load: {
        UserDefaults.standard.string(forKey: SupacodePaths.homeOverrideUserDefaultsKey)
      },
      save: { value in
        if let value {
          UserDefaults.standard.set(value, forKey: SupacodePaths.homeOverrideUserDefaultsKey)
        } else {
          UserDefaults.standard.removeObject(forKey: SupacodePaths.homeOverrideUserDefaultsKey)
        }
      }
    )
  }

  static var previewValue: SupacodeHomeOverridePersistence {
    .inMemory()
  }

  static var testValue: SupacodeHomeOverridePersistence {
    .inMemory()
  }
}

extension DependencyValues {
  nonisolated var supacodeHomeOverridePersistence: SupacodeHomeOverridePersistence {
    get { self[SupacodeHomeOverridePersistenceKey.self] }
    set { self[SupacodeHomeOverridePersistenceKey.self] = newValue }
  }
}

extension SupacodeHomeOverridePersistence {
  nonisolated static func inMemory() -> SupacodeHomeOverridePersistence {
    let storage = InMemorySupacodeHomeOverrideStorage()
    return SupacodeHomeOverridePersistence(
      load: {
        storage.load()
      },
      save: { value in
        storage.save(value)
      }
    )
  }
}

nonisolated final class InMemorySupacodeHomeOverrideStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  func load() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func save(_ value: String?) {
    lock.lock()
    defer { lock.unlock() }
    self.value = value
  }
}
