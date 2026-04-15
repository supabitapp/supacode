import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct AppTelemetryTests {
  @Test
  func configurationReadsTrackedInfoDictionary() throws {
    let configuration = try #require(
      AppTelemetry.Configuration(
        infoDictionary: [
          "PostHogAPIKey": "phc_test",
          "PostHogHost": "https://us.i.posthog.com",
        ]
      )
    )

    #expect(configuration.apiKey == "phc_test")
    #expect(configuration.host == "https://us.i.posthog.com")
  }

  @Test
  func configurationRejectsMissingOrInvalidValues() {
    #expect(
      AppTelemetry.Configuration(
        infoDictionary: [
          "PostHogAPIKey": "phc_test",
          "PostHogHost": "",
        ]
      ) == nil
    )

    #expect(AppTelemetry.Configuration(infoDictionary: [:]) == nil)
  }

  @Test
  func isEnabledRequiresAnalyticsAndNonDebugBuild() {
    #expect(AppTelemetry.isEnabled(settings: .default, isDebugBuild: false))
    #expect(
      !AppTelemetry.isEnabled(
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
          analyticsEnabled: false,
          crashReportsEnabled: true,
          githubIntegrationEnabled: true,
          deleteBranchOnDeleteWorktree: true,
          promptForWorktreeCreation: true
        ),
        isDebugBuild: false
      )
    )
    #expect(!AppTelemetry.isEnabled(settings: .default, isDebugBuild: true))
  }
}
