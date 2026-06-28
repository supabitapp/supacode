import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Caches the resolved `NSSound` for each `NotificationSound` so repeated
/// notifications don't reload the same file off disk. Main-actor isolated
/// because `NSSound` playback is.
@MainActor
private enum NotificationSoundCache {
  static var sounds: [NotificationSound: NSSound] = [:]

  static func resolve(_ sound: NotificationSound) -> NSSound? {
    if let cached = sounds[sound] { return cached }
    guard let made = sound.makeInAppSound() else { return nil }
    sounds[sound] = made
    return made
  }
}

struct NotificationSoundClient {
  var play: @MainActor @Sendable (_ sound: NotificationSound) -> Void
}

extension NotificationSoundClient: DependencyKey {
  static let liveValue = NotificationSoundClient(
    play: { sound in
      _ = NotificationSoundCache.resolve(sound)?.play()
    }
  )

  static let testValue = NotificationSoundClient(
    play: { _ in }
  )
}

extension DependencyValues {
  var notificationSoundClient: NotificationSoundClient {
    get { self[NotificationSoundClient.self] }
    set { self[NotificationSoundClient.self] = newValue }
  }
}
