import ComposableArchitecture
import PostHog
import SwiftUI

public nonisolated struct AnalyticsClient: Sendable {
  public var capture: @Sendable (_ event: String, _ properties: [String: Any]?) -> Void
  public var identify: @Sendable (_ distinctId: String) -> Void

  public init(
    capture: @escaping @Sendable (_ event: String, _ properties: [String: Any]?) -> Void,
    identify: @escaping @Sendable (_ distinctId: String) -> Void
  ) {
    self.capture = capture
    self.identify = identify
  }
}

extension AnalyticsClient: DependencyKey {
  public static let liveValue = AnalyticsClient(
    capture: { event, properties in
      #if !DEBUG
        @Shared(.settingsFile) var settingsFile
        guard settingsFile.global.analyticsEnabled else { return }
        PostHogSDK.shared.capture(event, properties: properties)
      #endif
    },
    identify: { distinctId in
      #if !DEBUG
        @Shared(.settingsFile) var settingsFile
        guard settingsFile.global.analyticsEnabled else { return }
        PostHogSDK.shared.identify(distinctId)
      #endif
    }
  )

  public static let testValue = AnalyticsClient(
    capture: { _, _ in },
    identify: { _ in }
  )
}

extension DependencyValues {
  public var analyticsClient: AnalyticsClient {
    get { self[AnalyticsClient.self] }
    set { self[AnalyticsClient.self] = newValue }
  }
}

private struct AnalyticsClientKey: EnvironmentKey {
  static let defaultValue = AnalyticsClient.liveValue
}

extension EnvironmentValues {
  public var analyticsClient: AnalyticsClient {
    get { self[AnalyticsClientKey.self] }
    set { self[AnalyticsClientKey.self] = newValue }
  }
}
