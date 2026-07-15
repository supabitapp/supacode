import ComposableArchitecture
import CustomDump
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureLifecycleTelemetryTests {
  @Test(.dependencies)
  func activationDebouncesForFifteenMinutes() async {
    let base = Date(timeIntervalSince1970: 1_000)
    let currentDate = LockIsolated(base)
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date = DateGenerator { currentDate.value }
      // Activation also kicks the debounced editor-availability sweep.
      $0.continuousClock = ImmediateClock()
      $0.analyticsClient.capture = { event, _ in
        events.withValue { $0.append(event) }
      }
    }

    // Activation also re-reads every repository's open action, so an edit made
    // while the app was away lands. The roster is empty here, so it resolves
    // nothing.
    await store.send(.applicationDidBecomeActive) {
      $0.appLifecycleEventDebouncer.lastActivatedAt = base
    }
    await store.receive(\.repositories.resolveOpenActions)
    expectNoDifference(events.value, ["app_activated_debounced"])

    currentDate.setValue(base.addingTimeInterval(899))
    await store.send(.applicationDidBecomeActive)
    await store.receive(\.repositories.resolveOpenActions)
    expectNoDifference(events.value, ["app_activated_debounced"])

    currentDate.setValue(base.addingTimeInterval(900))
    await store.send(.applicationDidBecomeActive) {
      $0.appLifecycleEventDebouncer.lastActivatedAt = base.addingTimeInterval(900)
    }
    await store.receive(\.repositories.resolveOpenActions)
    expectNoDifference(events.value, ["app_activated_debounced", "app_activated_debounced"])

    await store.finish()
  }

  @Test(.dependencies)
  func deactivationDebouncesForFifteenMinutes() async {
    let base = Date(timeIntervalSince1970: 2_000)
    let currentDate = LockIsolated(base)
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date = DateGenerator { currentDate.value }
      // Activation also kicks the debounced editor-availability sweep.
      $0.continuousClock = ImmediateClock()
      $0.analyticsClient.capture = { event, _ in
        events.withValue { $0.append(event) }
      }
    }

    await store.send(.applicationDidResignActive) {
      $0.appLifecycleEventDebouncer.lastDeactivatedAt = base
    }
    expectNoDifference(events.value, ["app_deactivated_debounced"])

    currentDate.setValue(base.addingTimeInterval(899))
    await store.send(.applicationDidResignActive)
    expectNoDifference(events.value, ["app_deactivated_debounced"])

    currentDate.setValue(base.addingTimeInterval(900))
    await store.send(.applicationDidResignActive) {
      $0.appLifecycleEventDebouncer.lastDeactivatedAt = base.addingTimeInterval(900)
    }
    expectNoDifference(events.value, ["app_deactivated_debounced", "app_deactivated_debounced"])

    await store.finish()
  }

  @Test(.dependencies)
  func activationAndDeactivationDebounceIndependently() async {
    let base = Date(timeIntervalSince1970: 3_000)
    let currentDate = LockIsolated(base)
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date = DateGenerator { currentDate.value }
      // Activation also kicks the debounced editor-availability sweep.
      $0.continuousClock = ImmediateClock()
      $0.analyticsClient.capture = { event, _ in
        events.withValue { $0.append(event) }
      }
    }

    await store.send(.applicationDidBecomeActive) {
      $0.appLifecycleEventDebouncer.lastActivatedAt = base
    }
    await store.receive(\.repositories.resolveOpenActions)

    currentDate.setValue(base.addingTimeInterval(1))
    await store.send(.applicationDidResignActive) {
      $0.appLifecycleEventDebouncer.lastDeactivatedAt = base.addingTimeInterval(1)
    }

    expectNoDifference(events.value, ["app_activated_debounced", "app_deactivated_debounced"])

    await store.finish()
  }
}
