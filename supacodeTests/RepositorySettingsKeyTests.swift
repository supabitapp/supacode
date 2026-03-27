import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct RepositorySettingsKeyTests {
  @Test func encodingOmitsNilWorktreeBaseRef() throws {
    let data = try JSONEncoder().encode(RepositorySettings.default)
    let json = String(bytes: data, encoding: .utf8) ?? ""

    #expect(!json.contains("worktreeBaseRef"))
    #expect(!json.contains("worktreeBaseDirectoryPath"))
  }

  @Test(.dependencies) func loadCreatesDefaultAndPersists() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    let settings = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(settings == RepositorySettings.default)

    let saved: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(
      saved.repositories[rootURL.path(percentEncoded: false)] == RepositorySettings.default
    )
  }

  @Test(.dependencies) func saveOverwritesExistingSettings() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    var updated = RepositorySettings.default
    updated.runScript = "echo updated"

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.repositories[rootURL.path(percentEncoded: false)] == updated)
  }

  @Test func decodeMissingDeleteScriptDefaultsToEmpty() throws {
    let data = Data(
      """
      {
        "setupScript": "echo setup",
        "runScript": "echo run",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.deleteScript.isEmpty)
  }

  @Test func decodeMissingArchiveScriptDefaultsToEmpty() throws {
    let data = Data(
      """
      {
        "setupScript": "echo setup",
        "runScript": "echo run",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.archiveScript.isEmpty)
  }

  @Test(.dependencies) func loadPrefersLocalSupacodeJSONOverGlobalEntry() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"
    var localSettings = RepositorySettings.default
    localSettings.runScript = "echo local"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    try localStorage.save(
      encode(localSettings),
      at: SupacodePaths.repositorySettingsURL(for: rootURL)
    )

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == localSettings)
  }

  @Test(.dependencies) func loadFallsBackToGlobalWhenLocalMissing() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == globalSettings)
  }

  @Test(.dependencies) func loadFallsBackToGlobalWhenLocalInvalid() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let localURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    try localStorage.save(Data("{".utf8), at: localURL)

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == globalSettings)
  }

  @Test(.dependencies) func saveWritesLocalWhenLocalFileExists() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let localURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    try localStorage.save(encode(.default), at: localURL)

    var updated = RepositorySettings.default
    updated.runScript = "echo local"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let localData = try #require(localStorage.data(at: localURL))
    let localDecoded = try JSONDecoder().decode(RepositorySettings.self, from: localData)
    #expect(localDecoded == updated)

    let globalSaved: SettingsFile = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      return settingsFile
    }

    #expect(globalSaved.repositories[repositoryID] == nil)
  }

  @Test(.dependencies) func saveWritesGlobalWhenLocalFileMissing() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let localURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    var updated = RepositorySettings.default
    updated.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let globalSaved: SettingsFile = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      return settingsFile
    }

    #expect(globalSaved.repositories[repositoryID] == updated)
    #expect(localStorage.data(at: localURL) == nil)
  }

  private func encode(_ settings: RepositorySettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(settings)
  }
}

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
