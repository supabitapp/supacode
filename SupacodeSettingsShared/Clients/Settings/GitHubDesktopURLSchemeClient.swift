import AppKit
import ComposableArchitecture
import CoreServices
import Foundation

public struct GitHubDesktopURLSchemeHandler: Equatable, Sendable {
  public var bundleIdentifier: String
  public var applicationName: String
  public var applicationURL: URL?

  public init(bundleIdentifier: String, applicationName: String, applicationURL: URL?) {
    self.bundleIdentifier = bundleIdentifier
    self.applicationName = applicationName
    self.applicationURL = applicationURL
  }
}

public nonisolated struct GitHubDesktopURLSchemeClient: Sendable {
  public var currentHandler: @MainActor @Sendable () async -> GitHubDesktopURLSchemeHandler?
  public var claim: @MainActor @Sendable () async throws -> Void

  public init(
    currentHandler: @escaping @MainActor @Sendable () async -> GitHubDesktopURLSchemeHandler?,
    claim: @escaping @MainActor @Sendable () async throws -> Void
  ) {
    self.currentHandler = currentHandler
    self.claim = claim
  }
}

public enum GitHubDesktopURLSchemeClientError: Error, Equatable, LocalizedError {
  case missingBundleIdentifier
  case launchServicesStatus(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .missingBundleIdentifier:
      "Supacode bundle identifier is unavailable."
    case .launchServicesStatus(let status):
      "LaunchServices rejected the GitHub Desktop URL scheme claim: \(status)."
    }
  }
}

extension GitHubDesktopURLSchemeClient: DependencyKey {
  public static let liveValue = Self(
    currentHandler: {
      guard
        let current = LSCopyDefaultHandlerForURLScheme("x-github-client" as CFString)?
          .takeRetainedValue() as String?
      else {
        return nil
      }

      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: current)
      let appName =
        appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
        ?? appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
        ?? appURL?.deletingPathExtension().lastPathComponent
        ?? current
      return GitHubDesktopURLSchemeHandler(
        bundleIdentifier: current,
        applicationName: appName,
        applicationURL: appURL
      )
    },
    claim: {
      guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        throw GitHubDesktopURLSchemeClientError.missingBundleIdentifier
      }

      let status = LSSetDefaultHandlerForURLScheme(
        "x-github-client" as CFString,
        bundleIdentifier as CFString
      )
      guard status == noErr else {
        throw GitHubDesktopURLSchemeClientError.launchServicesStatus(status)
      }
    }
  )

  public static let testValue = Self(
    currentHandler: { nil },
    claim: {}
  )
}

extension DependencyValues {
  public var githubDesktopURLSchemeClient: GitHubDesktopURLSchemeClient {
    get { self[GitHubDesktopURLSchemeClient.self] }
    set { self[GitHubDesktopURLSchemeClient.self] = newValue }
  }
}
