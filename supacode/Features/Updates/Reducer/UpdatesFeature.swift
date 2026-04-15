import ComposableArchitecture
import PostHog
import SupacodeSettingsShared

@Reducer
struct UpdatesFeature {
  @ObservableState
  struct State: Equatable {
    var didConfigureUpdates = false
  }

  enum Action {
    case applySettings(
      updateChannel: UpdateChannel,
      automaticallyChecks: Bool,
      automaticallyDownloads: Bool
    )
    case checkForUpdates
  }

  @Dependency(AnalyticsClient.self) private var analyticsClient
  @Dependency(UpdaterClient.self) private var updaterClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .applySettings(let channel, let checks, let downloads):
        let checkInBackground = !state.didConfigureUpdates
        state.didConfigureUpdates = true
        return .run { _ in
          await updaterClient.setUpdateChannel(channel)
          await updaterClient.configure(checks, downloads, checkInBackground)
        }

      case .checkForUpdates:
        analyticsClient.capture("update_checked", nil)
        return .run { _ in
          await updaterClient.checkForUpdates()
        }
      }
    }
  }
}
