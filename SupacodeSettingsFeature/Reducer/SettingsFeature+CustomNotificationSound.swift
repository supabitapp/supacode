import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

private nonisolated let customNotificationSoundLogger = SupaLogger("Settings")

extension SettingsFeature {
  /// Custom-sound file lifecycle kept separate from the general settings switch.
  static var customNotificationSoundReducer: some Reducer<State, Action> {
    @Dependency(AnalyticsClient.self) var analyticsClient
    @Dependency(CustomNotificationSoundClient.self) var customNotificationSoundClient
    @Dependency(NotificationSoundClient.self) var notificationSoundClient

    return Reduce { state, action in
      switch action {
      case .customNotificationSoundSelected(let url):
        guard !state.isManagingCustomNotificationSound else { return .none }
        state.isManagingCustomNotificationSound = true
        return .run { send in
          do {
            let sound = try await customNotificationSoundClient.importSound(url)
            await send(.customNotificationSoundImported(.success(sound)))
          } catch {
            await send(.customNotificationSoundImported(.failure(error)))
          }
        }

      case .customNotificationSoundImportFailed(let message):
        state.alert = AlertState {
          TextState("Unable to Import Sound")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState(message)
        }
        return .none

      case .customNotificationSoundImported(.success(let customSound)):
        state.isManagingCustomNotificationSound = false
        let replacedSound = state.customNotificationSound
        state.customNotificationSound = customSound
        state.notificationSound = .custom
        let configuration = state.notificationSoundConfiguration
        var effects: [Effect<Action>] = [
          Self.persist(state.globalSettings, analyticsClient: analyticsClient),
          .run { _ in await notificationSoundClient.play(configuration) },
        ]
        if let replacedSound, replacedSound != customSound {
          effects.append(
            .run { _ in
              do {
                try await customNotificationSoundClient.removeSound(replacedSound)
              } catch {
                customNotificationSoundLogger.warning(
                  "Could not remove the previous custom notification sound: \(error.localizedDescription)"
                )
              }
            }
          )
        }
        return .merge(effects)

      case .customNotificationSoundImported(.failure(let error)):
        state.isManagingCustomNotificationSound = false
        return .send(.customNotificationSoundImportFailed(error.localizedDescription))

      case .removeCustomNotificationSoundTapped:
        guard !state.isManagingCustomNotificationSound else { return .none }
        guard let customSound = state.customNotificationSound else { return .none }
        state.alert = AlertState {
          TextState("Remove \"\(customSound.displayName)\"?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemoveCustomNotificationSound) {
            TextState("Remove")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState("Supacode's managed copy of this sound will be deleted.")
        }
        return .none

      case .alert(.presented(.confirmRemoveCustomNotificationSound)):
        state.alert = nil
        guard let customSound = state.customNotificationSound else { return .none }
        state.isManagingCustomNotificationSound = true
        var settingsAfterRemoval = state.globalSettings
        settingsAfterRemoval.customNotificationSound = nil
        if settingsAfterRemoval.notificationSound == .custom {
          settingsAfterRemoval.notificationSound = GlobalSettings.default.notificationSound
        }
        return .merge(
          Self.persist(settingsAfterRemoval, analyticsClient: analyticsClient),
          .run { send in
            do {
              try await customNotificationSoundClient.removeSound(customSound)
              await send(.customNotificationSoundRemoved(.success(())))
            } catch {
              await send(.customNotificationSoundRemoved(.failure(error)))
            }
          }
        )

      case .customNotificationSoundRemoved(.success):
        state.isManagingCustomNotificationSound = false
        state.customNotificationSound = nil
        if state.notificationSound == .custom {
          state.notificationSound = GlobalSettings.default.notificationSound
        }
        return Self.persist(state.globalSettings, analyticsClient: analyticsClient)

      case .customNotificationSoundRemoved(.failure(let error)):
        state.isManagingCustomNotificationSound = false
        state.alert = AlertState {
          TextState("Unable to Remove Sound")
        } actions: {
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("OK")
          }
        } message: {
          TextState(error.localizedDescription)
        }
        return Self.persist(state.globalSettings, analyticsClient: analyticsClient)

      default:
        return .none
      }
    }
  }
}
