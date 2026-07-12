import PostHog
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
  func configKeepsLifecycleAutocaptureAndFiltersOpenBackground() throws {
    let configuration = try #require(
      AppTelemetry.Configuration(
        infoDictionary: [
          "PostHogAPIKey": "phc_test",
          "PostHogHost": "https://us.i.posthog.com",
        ]
      )
    )
    let config = AppTelemetry.makeConfig(configuration: configuration)

    #expect(config.captureApplicationLifecycleEvents)
    #expect(!config.enableSwizzling)
    #expect(!AppTelemetry.shouldSend(eventName: "Application Opened"))
    #expect(!AppTelemetry.shouldSend(eventName: "Application Backgrounded"))
    #expect(AppTelemetry.shouldSend(eventName: "Application Installed"))
    #expect(AppTelemetry.shouldSend(eventName: "Application Updated"))
    #expect(AppTelemetry.shouldSend(eventName: "repository_added"))
  }

  @Test
  func isEnabledRequiresAnalyticsAndNonDebugBuild() {
    #expect(AppTelemetry.isEnabled(settings: .default, isDebugBuild: false))
    #expect(
      !AppTelemetry.isEnabled(
        settings: GlobalSettings(
          appearanceMode: .system,
          defaultEditorID: OpenWorktreeAction.automaticSettingsID,
          updateChannel: .stable,
          updatesAutomaticallyCheckForUpdates: true,
          updatesAutomaticallyDownloadUpdates: false,
          inAppNotificationsEnabled: true,
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
