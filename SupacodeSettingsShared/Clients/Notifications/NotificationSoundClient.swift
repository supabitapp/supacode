import AppKit
import ComposableArchitecture
import Foundation

enum NotificationSoundResolver {
  static func make(
    _ configuration: NotificationSoundConfiguration,
    soundsDirectory: URL = ManagedNotificationSoundStorage.defaultSoundsDirectory,
    bundledSoundURL: (String, String) -> URL? = {
      Bundle.main.url(forResource: $0, withExtension: $1)
    },
    makeSound: (URL, Bool) -> NSSound? = {
      NSSound(contentsOf: $0, byReference: $1)
    }
  ) -> NSSound? {
    guard let source = configuration.source else { return nil }
    switch source {
    case .system(let name):
      return NSSound(named: name)
    case .bundled(let resource, let fileExtension):
      guard let url = bundledSoundURL(resource, fileExtension) else {
        SupaLogger("Notifications").warning(
          "Bundled \(resource).\(fileExtension) is missing; in-app sound will not play."
        )
        return nil
      }
      guard let made = makeSound(url, true) else {
        SupaLogger("Notifications").warning(
          "Bundled \(resource).\(fileExtension) could not be loaded as an NSSound."
        )
        return nil
      }
      return made
    case .custom(let fileName):
      let customSound = CustomNotificationSound(displayName: fileName, fileName: fileName)
      guard
        let url = ManagedNotificationSoundStorage.fileURL(
          for: customSound,
          soundsDirectory: soundsDirectory
        ),
        FileManager.default.fileExists(atPath: url.path)
      else {
        return nil
      }
      return makeSound(url, false)
    }
  }
}

/// Caches the resolved `NSSound` for each `NotificationSound` so repeated
/// notifications don't reload the same file off disk. Main-actor isolated
/// because `NSSound` playback is.
@MainActor
enum NotificationSoundCache {
  static var sounds: [NotificationSound: NSSound] = [:]

  static func resolve(
    _ configuration: NotificationSoundConfiguration,
    make: (NotificationSoundConfiguration) -> NSSound? = {
      NotificationSoundResolver.make($0)
    }
  ) -> NSSound? {
    if configuration.sound == .custom {
      guard let custom = make(configuration) else {
        SupaLogger("Notifications").warning(
          "Custom notification sound is unavailable; playing the default in-app sound."
        )
        return resolve(
          NotificationSoundConfiguration(sound: .hero, customSound: nil),
          make: make
        )
      }
      return custom
    }
    if let cached = sounds[configuration.sound] { return cached }
    guard let made = make(configuration) else { return nil }
    sounds[configuration.sound] = made
    return made
  }
}

public nonisolated struct NotificationSoundClient: Sendable {
  public var play: @MainActor @Sendable (_ configuration: NotificationSoundConfiguration) -> Void

  public init(
    play: @escaping @MainActor @Sendable (_ configuration: NotificationSoundConfiguration) -> Void
  ) {
    self.play = play
  }
}

extension NotificationSoundClient {
  public static let live = NotificationSoundClient(
    play: { configuration in
      _ = NotificationSoundCache.resolve(configuration)?.play()
    }
  )
}

extension NotificationSoundClient: DependencyKey {
  public static let liveValue = live

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
