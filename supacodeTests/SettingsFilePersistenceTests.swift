import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
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

  @Test(.dependencies) func decodesLegacyAutoArchiveTrueAsMergedWorktreeActionArchive() throws {
    let legacy = LegacySettingsFileWithArchiveFlag(
      global: LegacyGlobalSettingsWithArchiveFlag(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        automaticallyArchiveMergedWorktrees: true
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

    #expect(settings.global.mergedWorktreeAction == .archive)
  }

  @Test(.dependencies) func decodesLegacyAutoArchiveFalseAsMergedWorktreeActionNil() throws {
    let legacy = LegacySettingsFileWithArchiveFlag(
      global: LegacyGlobalSettingsWithArchiveFlag(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        automaticallyArchiveMergedWorktrees: false
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

    #expect(settings.global.mergedWorktreeAction == nil)
  }

  @Test(.dependencies) func roundTripsMergedWorktreeActionDelete() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.mergedWorktreeAction = .delete
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.mergedWorktreeAction == .delete)
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
    #expect(settings.global.updatesAutomaticallyCheckForUpdates == false)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
    #expect(settings.global.inAppNotificationsEnabled == true)
    // Missing key (pre-feature file) decodes to the default sound.
    #expect(settings.global.notificationSound == .hero)
    #expect(settings.global.systemNotificationsEnabled == false)
    // Missing key (pre-feature file) decodes to the default, now false.
    #expect(settings.global.moveNotifiedWorktreeToTop == false)
    #expect(settings.global.analyticsEnabled == true)
    #expect(settings.global.crashReportsEnabled == true)
    #expect(settings.global.githubIntegrationEnabled == true)
    #expect(settings.global.deleteBranchOnDeleteWorktree == true)
    #expect(settings.global.mergedWorktreeAction == nil)
    #expect(settings.global.promptForWorktreeCreation == true)
    #expect(settings.global.defaultWorktreeBaseDirectoryPath == nil)
    #expect(settings.global.defaultEditorID == OpenWorktreeAction.automaticSettingsID)
    #expect(settings.repositoryRoots.isEmpty)
    #expect(settings.pinnedWorktreeIDs.isEmpty)
    // Pre-existing files must not flip the toggle on upgrade.
    #expect(settings.global.terminalThemeSyncEnabled == false)
  }

  @Test func freshInstallDefaultsTerminalThemeSyncEnabledToTrue() {
    #expect(GlobalSettings.default.terminalThemeSyncEnabled == true)
  }

  @Test(.dependencies) func decodesLegacyConfirmBeforeQuitTrueAsAlways() throws {
    // Opt-out users (`confirmBeforeQuit = true` in the old single-toggle model)
    // must land on `.always`, NOT `.auto`. `.auto` would silently re-enable the
    // dialog only when active work exists, which is the opposite of what they
    // configured ("ask me every time, no matter what").
    let legacy = LegacySettingsFileWithQuitToggle(
      global: LegacyGlobalSettingsWithQuitToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        confirmBeforeQuit: true
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

    #expect(settings.global.confirmQuitMode == .always)
  }

  @Test(.dependencies) func decodesLegacyConfirmBeforeQuitFalseAsNever() throws {
    // Symmetric to the `true` case: explicit opt-out must stay opt-out.
    let legacy = LegacySettingsFileWithQuitToggle(
      global: LegacyGlobalSettingsWithQuitToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        confirmBeforeQuit: false
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

    #expect(settings.global.confirmQuitMode == .never)
  }

  @Test(.dependencies) func freshInstallDefaultsConfirmQuitModeToAuto() throws {
    // Neither the new key nor the legacy key is present (fresh-installed
    // bundle). The decode must fall through to `.auto`, the new default.
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

    #expect(settings.global.confirmQuitMode == .auto)
  }

  @Test(.dependencies) func roundTripsExplicitNotificationSound() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.notificationSound = .submarine }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    // An explicitly chosen sound must survive a save / reload round-trip.
    #expect(reloaded.global.notificationSound == .submarine)
  }

  @Test(.dependencies) func migratesLegacyNotificationSoundEnabledFalseToNever() throws {
    // A pre-picker file with the sound explicitly muted must stay muted, not
    // resurface as the default sound on upgrade.
    let legacy = LegacySettingsFileWithSoundToggle(
      global: LegacyGlobalSettingsWithSoundToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        notificationSoundEnabled: false
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

    #expect(settings.global.notificationSound == .never)
  }

  @Test(.dependencies) func migratesLegacyNotificationSoundEnabledTrueToDefault() throws {
    // Symmetric to the `false` case: the sound was on, so it folds to the default.
    let legacy = LegacySettingsFileWithSoundToggle(
      global: LegacyGlobalSettingsWithSoundToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        notificationSoundEnabled: true
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

    #expect(settings.global.notificationSound == .hero)
  }

  @Test(.dependencies) func decodesUnrecognizedNotificationSoundAsDefaultWithoutResettingSiblings() throws {
    // A hand-edited or downgraded file carrying a sound case this build doesn't
    // know yet. The `try?` must isolate the fallback to this one field.
    var global = GlobalSettings.default
    global.appearanceMode = .dark
    global.systemNotificationsEnabled = true
    global.updatesAutomaticallyDownloadUpdates = true

    let encoded = try JSONEncoder().encode(global)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict["notificationSound"] = "futureSoundFromNewerBuild"
    let data = try JSONSerialization.data(withJSONObject: ["global": globalDict, "repositories": [:]])
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The unknown sound falls back to the default...
    #expect(settings.global.notificationSound == .hero)
    // ...but the rest of the file survives. This is what `try?` buys over `try`.
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.systemNotificationsEnabled == true)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
  }

  @Test(.dependencies) func roundTripsExplicitTerminalThemeSyncEnabled() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.terminalThemeSyncEnabled = true }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    // Explicit `true` must survive the asymmetric missing-key fallback.
    #expect(reloaded.global.terminalThemeSyncEnabled == true)
  }

  @Test(.dependencies) func decodesMissingRemoteSessionPersistenceEnabledAsTrue() throws {
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

    // Pre-feature files opt in by default (the setting is an opt-out).
    #expect(settings.global.remoteSessionPersistenceEnabled == true)
  }

  @Test(.dependencies) func roundTripsExplicitRemoteSessionPersistenceDisabled() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.remoteSessionPersistenceEnabled = false }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.remoteSessionPersistenceEnabled == false)
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

private struct LegacySettingsFileWithArchiveFlag: Codable {
  var global: LegacyGlobalSettingsWithArchiveFlag
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithArchiveFlag: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var automaticallyArchiveMergedWorktrees: Bool
}

private struct LegacySettingsFileWithSoundToggle: Codable {
  var global: LegacyGlobalSettingsWithSoundToggle
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithSoundToggle: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var notificationSoundEnabled: Bool
}

private struct LegacySettingsFileWithQuitToggle: Codable {
  var global: LegacyGlobalSettingsWithQuitToggle
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithQuitToggle: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var confirmBeforeQuit: Bool
}
