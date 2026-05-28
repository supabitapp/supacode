import ComposableArchitecture
import SupacodeSettingsShared

struct GitLabIntegrationClient: Sendable {
  var isAvailable: @MainActor @Sendable () async -> Bool
}

private actor GitLabIntegrationAvailabilityCache {
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

private let gitlabIntegrationAvailabilityCache = GitLabIntegrationAvailabilityCache(
  ttl: .seconds(30)
)

extension GitLabIntegrationClient: DependencyKey {
  static let liveValue = GitLabIntegrationClient(
    isAvailable: {
      await gitlabIntegrationIsAvailable()
    }
  )
  static let testValue = GitLabIntegrationClient(
    isAvailable: { true }
  )
}

extension DependencyValues {
  var gitlabIntegration: GitLabIntegrationClient {
    get { self[GitLabIntegrationClient.self] }
    set { self[GitLabIntegrationClient.self] = newValue }
  }
}

@MainActor
private func gitlabIntegrationIsAvailable() async -> Bool {
  @Shared(.settingsFile) var settingsFile
  @Dependency(GitLabCLIClient.self) var gitlabCLI
  guard settingsFile.global.gitlabIntegrationEnabled else {
    await gitlabIntegrationAvailabilityCache.clear()
    return false
  }
  return await gitlabIntegrationAvailabilityCache.value {
    await gitlabCLI.isAvailable()
  }
}
