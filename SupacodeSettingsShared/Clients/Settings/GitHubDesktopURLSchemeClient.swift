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

private enum GitHubDesktopURLSchemes {
  static let primary = "x-github-client"
  static let all = [primary, "x-github-desktop-auth", "github-mac"]
}

extension GitHubDesktopURLSchemeClient: DependencyKey {
  public static let liveValue = Self(
    currentHandler: {
      guard
        let schemeURL = URL(string: "\(GitHubDesktopURLSchemes.primary)://openRepo/https://github.com/owner/repo"),
        let appURL = NSWorkspace.shared.urlForApplication(toOpen: schemeURL)
      else {
        return nil
      }

      let bundle = Bundle(url: appURL)
      let bundleIdentifier = bundle?.bundleIdentifier ?? appURL.path
      let appName =
        bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? appURL.deletingPathExtension().lastPathComponent
      return GitHubDesktopURLSchemeHandler(
        bundleIdentifier: bundleIdentifier,
        applicationName: appName,
        applicationURL: appURL
      )
    },
    claim: {
      guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        throw GitHubDesktopURLSchemeClientError.missingBundleIdentifier
      }

      for scheme in GitHubDesktopURLSchemes.all {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
        guard status == noErr else {
          throw GitHubDesktopURLSchemeClientError.launchServicesStatus(status)
        }
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
