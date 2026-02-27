import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct SettingsFilePersistenceTests {
  @Test(.dependencies) func loadWritesDefaultsWhenMissing() throws {
    let storage = SettingsTestStorage()

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings == .default)

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded == .default)
  }

  @Test(.dependencies) func saveAndReload() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b"]
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/wt-1"]
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.global.appearanceMode == .dark)
    #expect(reloaded.repositoryRoots == ["/tmp/repo-a", "/tmp/repo-b"])
    #expect(reloaded.pinnedWorktreeIDs == ["/tmp/repo-a/wt-1"])
  }

  @Test(.dependencies) func invalidJSONResetsToDefaults() throws {
    let storage = MutableTestStorage(initialData: Data("{".utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings == .default)

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded == .default)
  }

  @Test(.dependencies) func decodesMissingInAppNotificationsEnabled() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.confirmBeforeQuit == true)
    #expect(settings.global.updatesAutomaticallyCheckForUpdates == false)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
    #expect(settings.global.inAppNotificationsEnabled == true)
    #expect(settings.global.notificationSoundEnabled == true)
    #expect(settings.global.systemNotificationsEnabled == false)
    #expect(settings.global.moveNotifiedWorktreeToTop == true)
    #expect(settings.global.analyticsEnabled == true)
    #expect(settings.global.crashReportsEnabled == true)
    #expect(settings.global.githubIntegrationEnabled == true)
    #expect(settings.global.deleteBranchOnDeleteWorktree == true)
    #expect(settings.global.automaticallyArchiveMergedWorktrees == false)
    #expect(settings.global.promptForWorktreeCreation == true)
    #expect(settings.global.defaultWorktreeBaseDirectoryPath == nil)
    #expect(settings.global.defaultEditorID == OpenWorktreeAction.automaticSettingsID)
    #expect(settings.repositoryRoots.isEmpty)
    #expect(settings.pinnedWorktreeIDs.isEmpty)
  }
}

nonisolated private final class MutableTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private let initialData: Data

  init(initialData: Data) {
    self.initialData = initialData
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
    if let data {
      return data
    }
    return initialData
  }

  private func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    self.data = data
  }
}

private struct LegacySettingsFile: Codable {
  var global: LegacyGlobalSettings
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettings: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
}
