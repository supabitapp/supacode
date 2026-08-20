import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// The registered forges and per-repository resolution. The only place that
/// knows which forge implementations exist.
struct ForgeRegistry: Sendable {
  /// Resolve the forge serving one repository: per-repo override, then a
  /// known-host fast path, then membership in a CLI's authenticated-host set.
  var resolveForgeID: @MainActor @Sendable (URL, RemoteHost?) async -> ForgeID?
  var client: @Sendable (ForgeID) -> ForgeClient?
  var capabilities: @Sendable (ForgeID) -> ForgeCapabilities?
}

/// Short-lived cache for CLI authenticated-host reads, so per-repo resolution
/// on the refresh cadence doesn't spawn an auth-status process per repository.
private actor ForgeAuthenticatedHostsCache {
  private var cachedHosts: [ForgeID: (hosts: Set<String>, fetchedAt: ContinuousClock.Instant)] = [:]
  private let ttl: Duration = .seconds(30)
  private let clock = ContinuousClock()

  func hosts(for forgeID: ForgeID, fetch: @Sendable () async -> Set<String>) async -> Set<String> {
    if let cached = cachedHosts[forgeID], cached.fetchedAt.duration(to: clock.now) < ttl {
      return cached.hosts
    }
    let hosts = await fetch()
    cachedHosts[forgeID] = (hosts, clock.now)
    return hosts
  }
}

private let forgeAuthenticatedHostsCache = ForgeAuthenticatedHostsCache()

extension ForgeRegistry: DependencyKey {
  static let liveValue = ForgeRegistry(
    resolveForgeID: { rootURL, host in
      await ForgeRegistry.resolveLive(rootURL: rootURL, host: host)
    },
    client: { forgeID in
      switch forgeID {
      case .github: .github
      case .gitlab: .gitlab
      default: nil
      }
    },
    capabilities: { forgeID in
      switch forgeID {
      case .github: .github
      case .gitlab: .gitlab
      default: nil
      }
    }
  )

  static let testValue = ForgeRegistry(
    resolveForgeID: { _, _ in .github },
    client: { forgeID in
      switch forgeID {
      case .github: .github
      case .gitlab: .gitlab
      default: nil
      }
    },
    capabilities: { forgeID in
      switch forgeID {
      case .github: .github
      case .gitlab: .gitlab
      default: nil
      }
    }
  )

  @MainActor
  private static func resolveLive(rootURL: URL, host: RemoteHost?) async -> ForgeID? {
    @Dependency(GitClientDependency.self) var gitClient
    @Dependency(GithubCLIClient.self) var githubCLI
    @Dependency(GitLabCLIClient.self) var gitlabCLI
    @Shared(.settingsFile) var settingsFile

    let override = RepositorySettingsKey(rootURL: rootURL, host: host).currentSettings().forgeID
    let enabledForgeIDs = [ForgeID.github, .gitlab].filter {
      settingsFile.global.forgeIntegrationEnabled(forID: $0.rawValue)
    }
    let knownHostSubstrings: [ForgeID: [String]] = [
      .github: ["github"],
      .gitlab: ["gitlab"],
    ]
    let remoteHost = await gitClient.gitRemote(rootURL)?.host

    // Fast path: overrides and obvious hosts resolve without touching any
    // CLI's auth configuration.
    let quickCandidates = enabledForgeIDs.map {
      ForgeResolver.Candidate(
        id: $0,
        authenticatedHosts: [],
        knownHostSubstrings: knownHostSubstrings[$0] ?? []
      )
    }
    if override != nil || quickCandidates.contains(where: { candidate in
      guard let remoteHost else { return false }
      return candidate.knownHostSubstrings.contains(where: remoteHost.lowercased().contains)
    }) {
      return ForgeResolver.resolve(host: remoteHost, override: override, candidates: quickCandidates)
    }

    // Enterprise domains: membership in a CLI's own authenticated-host set.
    var candidates: [ForgeResolver.Candidate] = []
    for forgeID in enabledForgeIDs {
      let hosts = await forgeAuthenticatedHostsCache.hosts(for: forgeID) {
        switch forgeID {
        case .github: (try? await githubCLI.authenticatedHosts()) ?? []
        case .gitlab: await gitlabCLI.authenticatedHosts()
        default: []
        }
      }
      candidates.append(
        ForgeResolver.Candidate(
          id: forgeID,
          authenticatedHosts: hosts,
          knownHostSubstrings: knownHostSubstrings[forgeID] ?? []
        )
      )
    }
    return ForgeResolver.resolve(host: remoteHost, override: override, candidates: candidates)
  }
}
