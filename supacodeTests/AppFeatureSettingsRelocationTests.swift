import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureSettingsRelocationTests {
  @Test(.dependencies) func didNotFinishSetsAlertAndDismissClearsIt() async {
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      }
    }
    store.exhaustivity = .off

    await store.send(.settingsRelocationDidNotFinish(problems: ["Your repository list could not be written."]))
    #expect(store.state.alert?.title == TextState("Settings move incomplete"))

    await store.send(.alert(.dismiss))
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func settingsStoreUnreadableSetsAlertAndDismissClearsIt() async {
    let storage = SettingsTestStorage()
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      }
    }
    store.exhaustivity = .off

    await store.send(.settingsStoreUnreadable)
    #expect(store.state.alert?.title == TextState("Settings couldn't be read"))

    await store.send(.alert(.dismiss))
    #expect(store.state.alert == nil)
  }
}
