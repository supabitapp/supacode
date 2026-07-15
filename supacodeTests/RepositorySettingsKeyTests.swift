import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RepositorySettingsKeyTests {
  @Test func encodingOmitsNilWorktreeBaseRef() throws {
    let data = try JSONEncoder().encode(RepositorySettings.default)
    let json = String(bytes: data, encoding: .utf8) ?? ""

    #expect(!json.contains("worktreeBaseRef"))
    #expect(!json.contains("worktreeBaseDirectoryPath"))
    #expect(!json.contains("copyIgnoredOnWorktreeCreate"))
    #expect(!json.contains("copyUntrackedOnWorktreeCreate"))
    #expect(!json.contains("pullRequestMergeStrategy"))
  }

  @Test(.dependencies) func loadReturnsDefaultsWithoutPersistingThem() throws {
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

    // Seeding defaults here would mutate (and persist) the settings file from a
    // read, re-invalidating every observer. The entry only appears on a real save.
    #expect(saved.repositories[rootURL.path(percentEncoded: false)] == nil)
  }

  // MARK: - A read must never write (#657)

  /// Each evaluation rebuilds the `@Shared` reference (`PersistentReferences`
  /// caches weakly), so a writing `load` re-saves and re-invalidates observers
  /// on every read. A view body that observes `settingsFile` then loops.
  @Test(.dependencies) func repeatedLoadNeverWritesWhenLocalFileMissing() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo-no-local")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      _ = settingsFile
      globalStorage.resetCounts()

      for _ in 0..<10 {
        @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
        #expect(repositorySettings == RepositorySettings.default)
      }
    }

    #expect(globalStorage.saveCount == 0)
    #expect(localStorage.saveCount == 0)
  }

  @Test(.dependencies) func repeatedLoadNeverWritesWhenLocalFilePresent() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo-with-local")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    var localSettings = RepositorySettings.default
    localSettings.setupScript = "echo local"
    try localStorage.save(
      encode(localSettings),
      at: SupacodePaths.repositorySettingsURL(for: rootURL)
    )

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      _ = settingsFile
      globalStorage.resetCounts()

      for _ in 0..<10 {
        @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
        #expect(repositorySettings == localSettings)
      }
    }

    #expect(globalStorage.saveCount == 0)
    #expect(localStorage.saveCount == 0)
  }

  /// Most repos own no `supacode.json`, so that read must stay quiet while a real fault
  /// (permissions, a stalled mount) is logged. The live storage is `Data(contentsOf:)`,
  /// which reports an absent file as `.fileReadNoSuchFile` (260), not the
  /// `.fileNoSuchFile` (4) its name suggests. Assert against the error the real call
  /// throws: an in-memory double can be made to agree with whatever the classifier says.
  @Test func absentFileIsClassifiedFromTheErrorTheLiveStorageThrows() throws {
    let absent = URL(fileURLWithPath: "/tmp/supacode-absent-\(UUID().uuidString)/supacode.json")
    var thrown: (any Error)?
    do {
      _ = try Data(contentsOf: absent)
    } catch {
      thrown = error
    }

    let error = try #require(thrown)
    #expect(RepositoryLocalSettingsStorage.isMissingFile(error))
    #expect(!RepositoryLocalSettingsStorage.isMissingFile(CocoaError(.fileReadNoPermission)))
  }

  /// An undecodable `supacode.json` (merge markers, a stray comma) must survive a
  /// save. `load` falls back to the global settings, so encoding those defaults over
  /// the file would replace the user's scripts with the values its own failed decode
  /// produced. The write goes to the global settings file and the file is left alone.
  @Test(.dependencies) func saveNeverOverwritesAnUndecodableLocalSettingsFile() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo-with-corrupt-local")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let localURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    let corrupt = Data(#"{ "setupScript": "echo local",, }"#.utf8)
    try localStorage.save(corrupt, at: localURL)

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      // The undecodable file falls back to the global settings rather than throwing.
      #expect(repositorySettings == RepositorySettings.default)
      $repositorySettings.withLock { $0.setupScript = "echo new" }
    }

    #expect(localStorage.data(at: localURL) == corrupt)
    #expect(localStorage.saveCount == 0)
    #expect(globalStorage.saveCount > 0)
  }

  /// A remote repo always skips the local-file branch, so it took the writing
  /// path unconditionally.
  @Test(.dependencies) func repeatedLoadNeverWritesForRemoteRepository() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/srv/repo")
    let host = RemoteHost(alias: "box")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      _ = settingsFile
      globalStorage.resetCounts()

      for _ in 0..<10 {
        @Shared(.repositorySettings(rootURL, host: host)) var repositorySettings: RepositorySettings
        #expect(repositorySettings == RepositorySettings.default)
      }
    }

    #expect(globalStorage.saveCount == 0)
    #expect(localStorage.saveCount == 0)
  }

  /// The steady state for anyone who has ever saved repository settings: the
  /// global entry already exists. The old seeding `withLock` wrote back the same
  /// bytes here, so a save-counting assertion alone would not have caught it.
  @Test(.dependencies) func repeatedLoadNeverWritesWhenGlobalEntryAlreadyExists() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo-seeded-entry")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var seeded = RepositorySettings.default
    seeded.setupScript = "echo seeded"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock { $0.repositories[repositoryID] = seeded }
      globalStorage.resetCounts()

      for _ in 0..<10 {
        @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
        #expect(repositorySettings == seeded)
      }
    }

    #expect(globalStorage.saveCount == 0)
    #expect(localStorage.saveCount == 0)
  }

  /// The save is a *sibling* of the loop's engine, not its cause: `withLock` fires
  /// `withMutation(keyPath: \.value)` whether or not the closure changes anything,
  /// which is what re-invalidates every `settingsFile` observer mid-read. Observe
  /// that signal directly so a byte-identical-write dedupe in `save` could never
  /// make this pass while the loop is live.
  @Test(.dependencies) func repeatedLoadNeverMutatesSettingsFileObservers() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo-observed")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var seeded = RepositorySettings.default
    seeded.setupScript = "echo seeded"
    let mutations = LockIsolated(0)

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      // Held for the whole loop: the sharing cache is weak, so dropping this
      // would rebuild the reference and lose the observers under test. A view
      // observing `settingsFile` holds it exactly this way.
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock { $0.repositories[repositoryID] = seeded }

      for _ in 0..<10 {
        // Tracking is one-shot, so re-arm it on every read.
        withObservationTracking {
          _ = settingsFile
        } onChange: {
          mutations.withValue { $0 += 1 }
        }
        @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
        #expect(repositorySettings == seeded)
      }
    }

    #expect(mutations.value == 0)
  }

  @Test(.dependencies) func saveOverwritesExistingSettings() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    var updated = RepositorySettings.default
    updated.setupScript = "echo updated"

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

  @Test func decodeOldFormatPreservesExplicitOverrides() throws {
    let data = Data(
      """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "",
        "openActionID": "automatic",
        "copyIgnoredOnWorktreeCreate": false,
        "copyUntrackedOnWorktreeCreate": true,
        "pullRequestMergeStrategy": "squash"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.copyIgnoredOnWorktreeCreate == false)
    #expect(settings.copyUntrackedOnWorktreeCreate == true)
    #expect(settings.pullRequestMergeStrategy == .squash)
  }

  @Test func decodeMissingOptionalFieldsDefaultsToNil() throws {
    let data = Data(
      """
      {
        "setupScript": "",
        "runScript": "",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.copyIgnoredOnWorktreeCreate == nil)
    #expect(settings.copyUntrackedOnWorktreeCreate == nil)
    #expect(settings.pullRequestMergeStrategy == nil)
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
    globalSettings.setupScript = "echo global"
    var localSettings = RepositorySettings.default
    localSettings.setupScript = "echo local"

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
    globalSettings.setupScript = "echo global"

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
    globalSettings.setupScript = "echo global"

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
    updated.setupScript = "echo local"

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
    updated.setupScript = "echo global"

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

  // MARK: - Remote keying

  @Test(.dependencies) func remoteKeyBrandsByHostSoSamePathDoesNotCollide() throws {
    let storage = SettingsTestStorage()
    let path = "/srv/repo"
    let rootURL = URL(fileURLWithPath: path)
    let hostA = RemoteHost(alias: "box-a")
    let hostB = RemoteHost(alias: "box-b")

    var settingsA = RepositorySettings.default
    settingsA.setupScript = "echo a"
    var settingsB = RepositorySettings.default
    settingsB.setupScript = "echo b"

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL, host: hostA)) var forHostA: RepositorySettings
      $forHostA.withLock { $0 = settingsA }
      @Shared(.repositorySettings(rootURL, host: hostB)) var forHostB: RepositorySettings
      $forHostB.withLock { $0 = settingsB }
    }

    let saved: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(saved.repositories["box-a/srv/repo"] == settingsA)
    #expect(saved.repositories["box-b/srv/repo"] == settingsB)
    // The bare path key (a local repo at the same path) stays untouched.
    #expect(saved.repositories[path] == nil)
  }

  @Test(.dependencies) func remoteRepoIgnoresLocalSupacodeJSONOnLoad() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let path = "/srv/repo"
    let rootURL = URL(fileURLWithPath: path)
    let host = RemoteHost(alias: "box")

    // A local supacode.json physically present at the same path must never be
    // read for a remote repo (it would belong to a different local checkout).
    var localSettings = RepositorySettings.default
    localSettings.setupScript = "echo local-bleed"
    try localStorage.save(encode(localSettings), at: SupacodePaths.repositorySettingsURL(for: rootURL))

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL, host: host)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == RepositorySettings.default)
  }

  @Test(.dependencies) func remoteRepoNeverWritesLocalSupacodeJSON() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let path = "/srv/repo"
    let rootURL = URL(fileURLWithPath: path)
    let host = RemoteHost(alias: "box")
    let localURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    // Even with a pre-existing local file at the path, a remote save must route
    // to the global settings file (keyed by branded id), not the local disk.
    try localStorage.save(encode(.default), at: localURL)

    var updated = RepositorySettings.default
    updated.setupScript = "echo remote"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL, host: host)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock { $0 = updated }
    }

    let localData = try #require(localStorage.data(at: localURL))
    let localDecoded = try JSONDecoder().decode(RepositorySettings.self, from: localData)
    #expect(localDecoded == .default)

    let globalSaved: SettingsFile = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }
    #expect(globalSaved.repositories["box/srv/repo"] == updated)
  }

  private func encode(_ settings: RepositorySettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(settings)
  }
}
