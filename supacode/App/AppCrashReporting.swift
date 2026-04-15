import Foundation
import Sentry
import SupacodeSettingsShared

enum AppCrashReporting {
  struct Configuration: Equatable {
    let dsn: String

    init?(infoDictionary: [String: Any]) {
      guard let dsn = Self.string(infoDictionary["SentryDSN"]) else {
        return nil
      }
      self.dsn = dsn
    }

    private static func string(_ value: Any?) -> String? {
      guard let value = value as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  static func isEnabled(settings: GlobalSettings, isDebugBuild: Bool) -> Bool {
    settings.crashReportsEnabled && !isDebugBuild
  }

  @MainActor
  static func setup(settings: GlobalSettings, infoDictionary: [String: Any]) {
    #if DEBUG
      return
    #else
      guard isEnabled(settings: settings, isDebugBuild: false) else { return }
      guard let configuration = Configuration(infoDictionary: infoDictionary) else { return }
      SentrySDK.start { options in
        options.dsn = configuration.dsn
        options.tracesSampleRate = 1.0
        options.enableAppHangTracking = false
      }
    #endif
  }
}
