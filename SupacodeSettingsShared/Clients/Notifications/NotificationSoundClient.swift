import AppKit
import ComposableArchitecture
import Foundation

/// Caches the resolved `NSSound` for each `NotificationSound` so repeated
/// notifications don't reload the same file off disk. Main-actor isolated
/// because `NSSound` playback is.
@MainActor
private enum NotificationSoundCache {
  static var sounds: [NotificationSound: NSSound] = [:]

  static func resolve(_ sound: NotificationSound) -> NSSound? {
    if let cached = sounds[sound] { return cached }
    guard let made = make(sound) else { return nil }
    sounds[sound] = made
    return made
  }

  private static func make(_ sound: NotificationSound) -> NSSound? {
    // `.never` (and any future sourceless case) plays nothing.
    guard let source = sound.source else { return nil }
    switch source {
    case .system(let name):
      return NSSound(named: name)
    case .bundled(let resource, let fileExtension):
      // The bundled chime is a packaging invariant; a missing or unreadable
      // file means the sound is silently dead, so leave a trail.
      guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else {
        SupaLogger("Notifications").warning(
          "Bundled \(resource).\(fileExtension) is missing; in-app sound will not play.")
        return nil
      }
      guard let made = NSSound(contentsOf: url, byReference: true) else {
        SupaLogger("Notifications").warning("Bundled \(resource).\(fileExtension) could not be loaded as an NSSound.")
        return nil
      }
      return made
    }
  }
}

public nonisolated struct NotificationSoundClient: Sendable {
  public var play: @MainActor @Sendable (_ sound: NotificationSound) -> Void

  public init(play: @escaping @MainActor @Sendable (_ sound: NotificationSound) -> Void) {
    self.play = play
  }
}

extension NotificationSoundClient: DependencyKey {
  public static let liveValue = NotificationSoundClient(
    play: { sound in
      // `.never` resolves to no `NSSound`, so nothing plays.
      _ = NotificationSoundCache.resolve(sound)?.play()
    }
  )

  public static let testValue = NotificationSoundClient(
    play: { _ in }
  )
}

extension DependencyValues {
  public var notificationSoundClient: NotificationSoundClient {
    get { self[NotificationSoundClient.self] }
    set { self[NotificationSoundClient.self] = newValue }
  }
}
