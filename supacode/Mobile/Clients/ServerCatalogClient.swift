import ComposableArchitecture
import Foundation

struct ServerCatalogClient: Sendable {
  var load: @MainActor @Sendable () -> [MobileServer]
  var upsert: @MainActor @Sendable (MobileServer) -> Void
  var delete: @MainActor @Sendable (MobileServer.ID) -> Void
  var observe: @MainActor @Sendable () -> AsyncStream<[MobileServer]>
}

@MainActor
private final class ServerCatalogStorage {
  private static let storageKey = "com.supacode.mobile.serverConfigurations"
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var continuations: [UUID: AsyncStream<[MobileServer]>.Continuation] = [:]

  func loadSorted() -> [MobileServer] {
    sortServers(load())
  }

  func upsert(_ server: MobileServer) {
    var servers = load()
    let normalized = server.normalized()
    if let index = servers.firstIndex(where: { $0.id == normalized.id }) {
      servers[index] = normalized
    } else {
      servers.append(normalized)
    }
    let sorted = sortServers(servers)
    persist(sorted)
    notify(sorted)
  }

  func delete(_ id: MobileServer.ID) {
    var servers = load()
    servers.removeAll { $0.id == id }
    persist(servers)
    notify(servers)
  }

  func observe() -> AsyncStream<[MobileServer]> {
    let id = UUID()
    return AsyncStream { continuation in
      self.continuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        MainActor.assumeIsolated {
          _ = self?.continuations.removeValue(forKey: id)
        }
      }
    }
  }

  private func load() -> [MobileServer] {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return [] }
    return (try? decoder.decode([MobileServer].self, from: data)) ?? []
  }

  private func persist(_ servers: [MobileServer]) {
    guard let data = try? encoder.encode(servers) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }

  private func sortServers(_ servers: [MobileServer]) -> [MobileServer] {
    servers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  private func notify(_ servers: [MobileServer]) {
    for continuation in continuations.values {
      continuation.yield(servers)
    }
  }
}

extension ServerCatalogClient: DependencyKey {
  static let liveValue: ServerCatalogClient = {
    let catalog = ServerCatalogStorage()
    return ServerCatalogClient(
      load: {
        catalog.loadSorted()
      },
      upsert: { server in
        catalog.upsert(server)
      },
      delete: { id in
        catalog.delete(id)
      },
      observe: {
        catalog.observe()
      }
    )
  }()

  static let testValue = ServerCatalogClient(
    load: { [] },
    upsert: { _ in },
    delete: { _ in },
    observe: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var serverCatalogClient: ServerCatalogClient {
    get { self[ServerCatalogClient.self] }
    set { self[ServerCatalogClient.self] = newValue }
  }
}
