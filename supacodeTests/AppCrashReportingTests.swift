import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AppCrashReportingTests {
  @Test
  func configurationReadsTrackedInfoDictionary() throws {
    let configuration = try #require(
      AppCrashReporting.Configuration(
        infoDictionary: [
          "SentryDSN": "https://examplePublicKey@o0.ingest.us.sentry.io/1"
        ]
      )
    )

    #expect(configuration.dsn == "https://examplePublicKey@o0.ingest.us.sentry.io/1")
  }

  @Test
  func configurationRejectsMissingOrInvalidValues() {
    #expect(
      AppCrashReporting.Configuration(
        infoDictionary: [
          "SentryDSN": ""
        ]
      ) == nil
    )

    #expect(AppCrashReporting.Configuration(infoDictionary: [:]) == nil)
  }

  @Test
  func isEnabledRequiresCrashReportsAndNonDebugBuild() {
    #expect(AppCrashReporting.isEnabled(settings: .default, isDebugBuild: false))
    #expect(
      !AppCrashReporting.isEnabled(
        settings: GlobalSettings(
          appearanceMode: .system,
          defaultEditorID: OpenWorktreeAction.automaticSettingsID,
          confirmBeforeQuit: true,
          updateChannel: .stable,
          updatesAutomaticallyCheckForUpdates: true,
          updatesAutomaticallyDownloadUpdates: false,
          inAppNotificationsEnabled: true,
          notificationSoundEnabled: true,
          moveNotifiedWorktreeToTop: true,
          analyticsEnabled: true,
          crashReportsEnabled: false,
          githubIntegrationEnabled: true,
          deleteBranchOnDeleteWorktree: true,
          promptForWorktreeCreation: true
        ),
        isDebugBuild: false
      )
    )
    #expect(!AppCrashReporting.isEnabled(settings: .default, isDebugBuild: true))
  }
}
