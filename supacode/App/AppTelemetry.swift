import Foundation
import PostHog
import SupacodeSettingsShared

enum AppTelemetry {
  struct Configuration: Equatable {
    let apiKey: String
    let host: String

    init?(infoDictionary: [String: Any]) {
      guard
        let apiKey = Self.string(infoDictionary["PostHogAPIKey"]),
        let host = Self.string(infoDictionary["PostHogHost"])
      else {
        return nil
      }

      self.apiKey = apiKey
      self.host = host
    }

    private static func string(_ value: Any?) -> String? {
      guard let value = value as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  static func isEnabled(settings: GlobalSettings, isDebugBuild: Bool) -> Bool {
    settings.analyticsEnabled && !isDebugBuild
  }

  static func makeConfig(configuration: Configuration) -> PostHogConfig {
    let config = PostHogConfig(projectToken: configuration.apiKey, host: configuration.host)
    config.captureApplicationLifecycleEvents = true
    config.enableSwizzling = false
    config.setBeforeSend { event in
      shouldSend(eventName: event.event) ? event : nil
    }
    return config
  }

  static func shouldSend(eventName: String) -> Bool {
    switch eventName {
    case "Application Opened", "Application Backgrounded":
      return false
    default:
      return true
    }
  }

  @MainActor
  static func setup(
    settings: GlobalSettings,
    infoDictionary: [String: Any],
    hardwareUUID: String? = HardwareInfo.uuid
  ) {
    #if DEBUG
      return
    #else
      guard isEnabled(settings: settings, isDebugBuild: false) else { return }
      guard let configuration = Configuration(infoDictionary: infoDictionary) else { return }
      let config = makeConfig(configuration: configuration)
      PostHogSDK.shared.setup(config)
      if let hardwareUUID {
        PostHogSDK.shared.identify(hardwareUUID)
      }
      PostHogSDK.shared.capture("app_launched")
    #endif
  }
}
