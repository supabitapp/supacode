import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct RepositorySettingsKeyTests {
  @Test func encodingOmitsNilRepositoryName() throws {
    let data = try JSONEncoder().encode(RepositorySettings.default)
    let json = String(bytes: data, encoding: .utf8) ?? ""

    #expect(!json.contains("repositoryName"))
  }

  @Test func encodingOmitsNilWorktreeBaseRef() throws {
    let data = try JSONEncoder().encode(RepositorySettings.default)
    let json = String(bytes: data, encoding: .utf8) ?? ""

    #expect(!json.contains("worktreeBaseRef"))
  }

  @Test func decodingMissingRepositoryNameDefaultsToNil() throws {
    let data = Data(
      """
      {
        "copyIgnoredOnWorktreeCreate": false,
        "copyUntrackedOnWorktreeCreate": false,
        "openActionID": "automatic",
        "pullRequestMergeStrategy": "merge",
        "runScript": "npm run dev",
        "setupScript": "echo setup"
      }
      """.utf8
    )

    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.repositoryName == nil)
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

    var settings = RepositorySettings.default
    settings.runScript = "echo updated"
    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = settings
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.repositories[rootURL.path(percentEncoded: false)] == settings)
  }
}
