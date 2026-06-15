import AppKit
import ComposableArchitecture
import Foundation

private let appNotificationSound: NSSound? = {
  guard let url = Bundle.main.url(forResource: "notification", withExtension: "wav") else {
    return nil
  }
  return NSSound(contentsOf: url, byReference: true)
}()

struct NotificationSoundClient {
  var play: @MainActor @Sendable () -> Void
}

extension NotificationSoundClient: DependencyKey {
  static let liveValue = NotificationSoundClient(
    play: {
      _ = appNotificationSound?.play()
    }
  )

  static let testValue = NotificationSoundClient(
    play: {}
  )
}

extension DependencyValues {
  var notificationSoundClient: NotificationSoundClient {
    get { self[NotificationSoundClient.self] }
    set { self[NotificationSoundClient.self] = newValue }
  }
}
