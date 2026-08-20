import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Registered forges and per-repository resolution: override, exact known
/// hosts, authenticated-host membership, substrings; never a default.
struct ForgeRegistry: Sendable {
  var resolveForgeID: @MainActor @Sendable (URL, RemoteHost?) async -> ForgeID?
  var client: @Sendable (ForgeID) -> ForgeClient?
  var capabilities: @Sendable (ForgeID) -> ForgeCapabilities?
}

/// Short-lived caches so bursts of per-repo resolution (selection refreshes,
/// user actions, the sweep itself) don't spawn an auth-status or git process
/// per call.
private actor ForgeResolutionCache {
  private var hostsByForge: [ForgeID: (hosts: Set<String>, fetchedAt: ContinuousClock.Instant)] = [:]
  private var remoteHostsByRepo: [URL: (host: String?, fetchedAt: ContinuousClock.Instant)] = [:]
  private let ttl: Duration = .seconds(30)
  // Nil can mean either "no remote" or a transient git failure; keep it long
  // enough to spare the sweep, short enough that a fixed remote is picked up.
  private let negativeTTL: Duration = .seconds(5)
  private let clock = ContinuousClock()

  func authenticatedHosts(
    for forgeID: ForgeID,
    fetch: @Sendable () async throws -> Set<String>
  ) async -> Set<String> {
    if let cached = hostsByForge[forgeID], cached.fetchedAt.duration(to: clock.now) < ttl {
      return cached.hosts
    }
    do {
      let hosts = try await fetch()
      hostsByForge[forgeID] = (hosts, clock.now)
      return hosts
    } catch {
      // A transient failure must not pin an empty host set for a full TTL.
      SupaLogger("ForgeRegistry").warning("Authenticated-hosts read failed for \(forgeID.rawValue): \(error)")
      return hostsByForge[forgeID]?.hosts ?? []
    }
  }

  func remoteHost(
    for rootURL: URL,
    fetch: @Sendable () async -> String?
  ) async -> String? {
    if let cached = remoteHostsByRepo[rootURL] {
      let age = cached.fetchedAt.duration(to: clock.now)
      if age < (cached.host == nil ? negativeTTL : ttl) {
        return cached.host
      }
    }
    var host = await fetch()
    if host?.isEmpty == true {
      host = nil
    }
    remoteHostsByRepo[rootURL] = (host, clock.now)
    return host
  }
}

private let forgeResolutionCache = ForgeResolutionCache()

extension ForgeRegistry {
  /// Every registered forge, in a stable dispatch order.
  nonisolated static let registeredForgeIDs: [ForgeID] = [.github, .gitlab]

  /// Enabled forges in registry order, the one filter every gate shares.
  nonisolated static func enabledForgeIDs(in settings: GlobalSettings) -> [ForgeID] {
    var enabled: [ForgeID] = []
    for forgeID in registeredForgeIDs {
      guard settings.forgeIntegrationEnabled(forID: forgeID.rawValue) else { continue }
      enabled.append(forgeID)
    }
    return enabled
  }

  nonisolated static func registeredClient(for forgeID: ForgeID) -> ForgeClient? {
    switch forgeID {
    case .github: .github
    case .gitlab: .gitlab
    default: nil
    }
  }

  nonisolated static func knownHostSubstrings(for forgeID: ForgeID) -> [String] {
    switch forgeID {
    case .github: ["github"]
    case .gitlab: ["gitlab"]
    default: []
    }
  }

  nonisolated static func candidate(
    for forgeID: ForgeID,
    authenticatedHosts: Set<String>
  ) -> ForgeResolver.Candidate {
    ForgeResolver.Candidate(
      id: forgeID,
      authenticatedHosts: authenticatedHosts,
      knownHostSubstrings: knownHostSubstrings(for: forgeID)
    )
  }
}

extension ForgeRegistry: DependencyKey {
  static let liveValue = ForgeRegistry(
    resolveForgeID: { rootURL, host in
      await ForgeRegistry.resolveLive(rootURL: rootURL, host: host)
    },
    client: { forgeID in
      ForgeRegistry.registeredClient(for: forgeID)
    },
    capabilities: { forgeID in
      ForgeCapabilities.forID(forgeID)
    }
  )

  static let testValue = ForgeRegistry(
    resolveForgeID: { _, _ in .github },
    client: { forgeID in
      ForgeRegistry.registeredClient(for: forgeID)
    },
    capabilities: { forgeID in
      ForgeCapabilities.forID(forgeID)
    }
  )

  @MainActor
  private static func resolveLive(rootURL: URL, host: RemoteHost?) async -> ForgeID? {
    @Shared(.settingsFile) var settingsFile

    let enabledForgeIDs = enabledForgeIDs(in: settingsFile.global)
    // An explicit override needs no remote read.
    let override = RepositorySettingsKey(rootURL: rootURL, host: host).currentSettings().forgeID
    if let override, !override.isEmpty {
      return ForgeResolver.resolve(
        host: nil,
        override: override,
        candidates: enabledForgeIDs.map { candidate(for: $0, authenticatedHosts: []) }
      )
    }

    @Dependency(GitClientDependency.self) var gitClient
    let remoteHost = await forgeResolutionCache.remoteHost(for: rootURL) {
      await gitClient.gitRemote(rootURL)?.host
    }
    guard let remoteHost = remoteHost?.lowercased(), !remoteHost.isEmpty else { return nil }

    // Exact well-known hosts resolve without touching any CLI's auth
    // configuration; ambiguous hosts take the full ladder below.
    let exactKnownHosts: [String: ForgeID] = ["github.com": .github, "gitlab.com": .gitlab]
    if let known = exactKnownHosts[remoteHost], enabledForgeIDs.contains(known) {
      return known
    }

    @Dependency(GithubCLIClient.self) var githubCLI
    @Dependency(GitLabCLIClient.self) var gitlabCLI
    var candidates: [ForgeResolver.Candidate] = []
    for forgeID in enabledForgeIDs {
      let hosts = await forgeResolutionCache.authenticatedHosts(for: forgeID) {
        switch forgeID {
        case .github: try await githubCLI.authenticatedHosts()
        case .gitlab: await gitlabCLI.authenticatedHosts()
        default: []
        }
      }
      candidates.append(candidate(for: forgeID, authenticatedHosts: hosts))
    }
    return ForgeResolver.resolve(host: remoteHost, override: nil, candidates: candidates)
  }
}
