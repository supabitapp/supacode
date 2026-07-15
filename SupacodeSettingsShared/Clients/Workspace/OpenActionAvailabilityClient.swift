import AppKit
import ComposableArchitecture
import Foundation

/// Editor availability, sourced from LaunchServices. Every lookup is a
/// synchronous XPC round-trip, so callers must resolve this once off the main
/// thread and cache the result, never probe it from a menu build or a body eval.
public nonisolated struct OpenActionAvailabilityClient: Sendable {
  /// The installed subset of `OpenWorktreeAction.menuOrder`, in menu order.
  public var installedActions: @Sendable () -> [OpenWorktreeAction]
  /// The app bundle URL for a bundle identifier, or `nil` when it isn't installed.
  public var applicationURL: @Sendable (String) -> URL?

  public init(
    installedActions: @escaping @Sendable () -> [OpenWorktreeAction],
    applicationURL: @escaping @Sendable (String) -> URL?
  ) {
    self.installedActions = installedActions
    self.applicationURL = applicationURL
  }
}

extension OpenActionAvailabilityClient: DependencyKey {
  public static let liveValue = Self(
    installedActions: {
      OpenWorktreeAction.menuOrder.filter { action in
        guard action.requiresInstalledApplication else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.bundleIdentifier) != nil
      }
    },
    applicationURL: { bundleIdentifier in
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
  )

  /// A deterministic fixture, so resolution is testable without a host's app list.
  public static let testValue = Self(
    installedActions: { [.zed, .finder, .terminal, .editor] },
    applicationURL: { _ in nil }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var openActionAvailability: OpenActionAvailabilityClient {
    get { self[OpenActionAvailabilityClient.self] }
    set { self[OpenActionAvailabilityClient.self] = newValue }
  }
}
