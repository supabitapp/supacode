import ComposableArchitecture
import SupacodeSettingsShared

struct GithubIntegrationClient: Sendable {
  var isAvailable: @MainActor @Sendable () async -> Bool
}

private actor GithubIntegrationAvailabilityCache {
  private struct Entry {
    let value: Bool
    let fetchedAt: ContinuousClock.Instant
  }

  private let ttl: Duration
  private let clock = ContinuousClock()
  private var cachedEntry: Entry?
  private var inFlightTask: Task<Bool, Never>?

  init(ttl: Duration) {
    self.ttl = ttl
  }

  func value(orFetch fetch: @Sendable @escaping () async -> Bool) async -> Bool {
    let now = clock.now
    if let cachedEntry,
      cachedEntry.fetchedAt.duration(to: now) < ttl
    {
      return cachedEntry.value
    }

    if let inFlightTask {
      return await inFlightTask.value
    }

    let task = Task { await fetch() }
    inFlightTask = task
    let value = await task.value
    cachedEntry = Entry(value: value, fetchedAt: clock.now)
    inFlightTask = nil
    return value
  }

  func clear() {
    inFlightTask?.cancel()
    inFlightTask = nil
    cachedEntry = nil
  }
}

private let githubIntegrationAvailabilityCache = GithubIntegrationAvailabilityCache(
  ttl: .seconds(30)
)

extension GithubIntegrationClient: DependencyKey {
  static let liveValue = GithubIntegrationClient(
    isAvailable: {
      await githubIntegrationIsAvailable()
    }
  )
  static let testValue = GithubIntegrationClient(
    isAvailable: { true }
  )
}

extension DependencyValues {
  var githubIntegration: GithubIntegrationClient {
    get { self[GithubIntegrationClient.self] }
    set { self[GithubIntegrationClient.self] = newValue }
  }
}

@MainActor
private func githubIntegrationIsAvailable() async -> Bool {
  @Shared(.settingsFile) var settingsFile
  @Dependency(GithubCLIClient.self) var githubCLI
  guard settingsFile.global.githubIntegrationEnabled else {
    await githubIntegrationAvailabilityCache.clear()
    return false
  }
  return await githubIntegrationAvailabilityCache.value {
    await githubCLI.isAvailable()
  }
}
