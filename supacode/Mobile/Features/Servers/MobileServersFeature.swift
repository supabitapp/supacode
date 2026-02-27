import ComposableArchitecture
import Foundation

@Reducer
struct MobileServersFeature {
  @ObservableState
  struct State: Equatable {
    var servers: IdentifiedArrayOf<MobileServer> = []
    var isLoading = false
  }

  enum Action {
    case task
    case loaded([MobileServer])
    case serversUpdated([MobileServer])
    case upsert(MobileServer)
    case delete(MobileServer.ID)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case serverDeleted(MobileServer.ID)
    }
  }

  @Dependency(ServerCatalogClient.self) private var serverCatalogClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        state.isLoading = true
        return .merge(
          .run { [serverCatalogClient] send in
            let servers = await MainActor.run { serverCatalogClient.load() }
            await send(.loaded(servers))
          },
          .run { [serverCatalogClient] send in
            let stream = await MainActor.run { serverCatalogClient.observe() }
            for await servers in stream {
              await send(.serversUpdated(servers))
            }
          }
        )

      case .loaded(let servers):
        state.servers = IdentifiedArray(uniqueElements: servers)
        state.isLoading = false
        return .none

      case .serversUpdated(let servers):
        state.servers = IdentifiedArray(uniqueElements: servers)
        return .none

      case .upsert(let server):
        return .run { [serverCatalogClient] _ in
          await MainActor.run { serverCatalogClient.upsert(server) }
        }

      case .delete(let id):
        return .run { [serverCatalogClient] send in
          await MainActor.run { serverCatalogClient.delete(id) }
          await send(.delegate(.serverDeleted(id)))
        }

      case .delegate:
        return .none
      }
    }
  }
}
