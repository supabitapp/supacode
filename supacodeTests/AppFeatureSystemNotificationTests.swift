import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureSystemNotificationTests {
  @Test(.dependencies) func firstTimeDeniedTurnsSystemNotificationsBackOffWithAlert() async {
    let storage = SettingsTestStorage()
    let authorizationRequests = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.authorizationStatus = { .notDetermined }
        $0.systemNotificationClient.requestAuthorization = {
          authorizationRequests.withValue { $0 += 1 }
          return SystemNotificationClient.AuthorizationRequestResult(
            granted: false,
            errorMessage: "Mock request error"
          )
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.binding(.set(\.systemNotificationsEnabled, true)))) {
      $0.settings.systemNotificationsEnabled = true
    }
    await store.receive(\.systemNotificationsPermissionFailed)
    await store.receive(\.settings.setSystemNotificationsEnabled) {
      $0.settings.systemNotificationsEnabled = false
    }
    let expectedAlert = AlertState<SettingsFeature.Alert> {
      TextState("Enable Notifications in System Settings")
    } actions: {
      ButtonState(action: .openSystemNotificationSettings) {
        TextState("Open System Settings")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("Supacode cannot send system notifications.\n\nError: Mock request error")
    }
    await store.receive(\.settings.showNotificationPermissionAlert) {
      $0.settings.alert = expectedAlert
    }

    #expect(authorizationRequests.value == 1)
    #expect(store.state.settings.systemNotificationsEnabled == false)
    #expect(store.state.settings.alert == expectedAlert)
  }

  @Test(.dependencies) func deniedStatusShowsAlertAndOpensSystemSettings() async {
    let storage = SettingsTestStorage()
    let authorizationRequests = LockIsolated(0)
    let openedSettings = LockIsolated(0)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      TestStore(initialState: AppFeature.State()) {
        AppFeature()
      } withDependencies: {
        $0.systemNotificationClient.authorizationStatus = { .denied }
        $0.systemNotificationClient.requestAuthorization = {
          authorizationRequests.withValue { $0 += 1 }
          return SystemNotificationClient.AuthorizationRequestResult(
            granted: false,
            errorMessage: "Mock request error"
          )
        }
        $0.systemNotificationClient.openSettings = {
          openedSettings.withValue { $0 += 1 }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.settings(.binding(.set(\.systemNotificationsEnabled, true)))) {
      $0.settings.systemNotificationsEnabled = true
    }
    await store.receive(\.systemNotificationsPermissionFailed)
    await store.receive(\.settings.setSystemNotificationsEnabled) {
      $0.settings.systemNotificationsEnabled = false
    }
    let expectedAlert = AlertState<SettingsFeature.Alert> {
      TextState("Enable Notifications in System Settings")
    } actions: {
      ButtonState(action: .openSystemNotificationSettings) {
        TextState("Open System Settings")
      }
      ButtonState(role: .cancel, action: .dismiss) {
        TextState("Cancel")
      }
    } message: {
      TextState("Supacode cannot send system notifications.\n\nError: Authorization status is denied.")
    }
    await store.receive(\.settings.showNotificationPermissionAlert) {
      $0.settings.alert = expectedAlert
    }

    #expect(authorizationRequests.value == 0)
    #expect(store.state.settings.systemNotificationsEnabled == false)
    #expect(store.state.settings.alert == expectedAlert)

    await store.send(.settings(.alert(.presented(.openSystemNotificationSettings)))) {
      $0.settings.alert = nil
    }
    await store.finish()
    #expect(openedSettings.value == 1)
  }

  @Test(.dependencies) func notificationReceivedSendsSystemNotificationWhenEnabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let sends = LockIsolated<[(String, String)]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { title, body, _ in
        sends.withValue { $0.append((title, body)) }
      }
      $0.terminalClient.tabID = { _, _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(sends.value.count == 1)
    #expect(sends.value.first?.0 == "Done")
    #expect(sends.value.first?.1 == "Build succeeded")
  }

  @Test(.dependencies) func notificationReceivedSkipsSystemNotificationWhenSurfaceIsViewed() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { _, _, _ in
        sends.withValue { $0 += 1 }
      }
      $0.terminalClient.tabID = { _, _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    #expect(sends.value == 0)
  }

  @Test(.dependencies) func notificationReceivedSendsSystemNotificationForViewedSurfaceWhenMuteDisabled()
    async
  {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    globalSettings.muteNotificationsForActiveSurface = false
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { _, _, _ in
        sends.withValue { $0 += 1 }
      }
      $0.terminalClient.tabID = { _, _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    #expect(sends.value == 1)
  }

  @Test(.dependencies) func notificationReceivedPlaysLocalSoundForViewedSurfaceWhenMuteDisabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSound = .hero
    globalSettings.muteNotificationsForActiveSurface = false
    let plays = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { _ in
        plays.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    #expect(plays.value == 1)
  }

  @Test(.dependencies) func notificationReceivedSkipsLocalSoundWhenSurfaceIsViewed() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSound = .hero
    let plays = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { _ in
        plays.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    #expect(plays.value == 0)
  }

  @Test(.dependencies) func notificationReceivedSkipsBothChannelsForViewedSurface() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    globalSettings.notificationSound = .hero
    // muteNotificationsForActiveSurface defaults to true; the muted banner must
    // not leak into the sound fallback.
    let sends = LockIsolated(0)
    let plays = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.systemNotificationClient.send = { _, _, _ in
        sends.withValue { $0 += 1 }
      }
      $0.notificationSoundClient.play = { _ in
        plays.withValue { $0 += 1 }
      }
      $0.terminalClient.tabID = { _, _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: true
        )
      )
    )
    await store.finish()

    #expect(sends.value == 0)
    #expect(plays.value == 0)
  }

  @Test(.dependencies) func notificationReceivedSkipsLocalSoundWhenSystemNotificationsEnabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = true
    let plays = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { _ in
        plays.withValue { $0 += 1 }
      }
      $0.systemNotificationClient.send = { _, _, _ in }
      $0.terminalClient.tabID = { _, _ in nil }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(plays.value == 0)
  }

  @Test(.dependencies) func notificationReceivedPlaysLocalSoundWhenSystemNotificationsDisabled() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSound = .funk
    let plays = LockIsolated<[NotificationSound]>([])
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { sound in
        plays.withValue { $0.append(sound) }
      }
      $0.systemNotificationClient.send = { _, _, _ in
        sends.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(plays.value == [.funk])
    #expect(sends.value == 0)
  }

  @Test(.dependencies) func notificationReceivedSkipsLocalSoundWhenNever() async {
    var globalSettings = GlobalSettings.default
    globalSettings.systemNotificationsEnabled = false
    globalSettings.notificationSound = .never
    let plays = LockIsolated<[NotificationSound]>([])
    let sends = LockIsolated(0)
    let store = TestStore(
      initialState: AppFeature.State(
        settings: SettingsFeature.State(settings: globalSettings)
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.notificationSoundClient.play = { sound in
        plays.withValue { $0.append(sound) }
      }
      $0.systemNotificationClient.send = { _, _, _ in
        sends.withValue { $0 += 1 }
      }
    }
    store.exhaustivity = .off

    await store.send(
      .terminalEvent(
        .notificationReceived(
          worktreeID: "/tmp/repo/wt-1",
          surfaceID: UUID(),
          title: "Done",
          body: "Build succeeded",
          isViewed: false
        )
      )
    )
    await store.finish()

    #expect(plays.value.isEmpty)
    #expect(sends.value == 0)
  }
}
