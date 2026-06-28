import AppKit
import UserNotifications

/// User-selectable notification sound. Applies to both the macOS system
/// notification banner path (`UNUserNotificationCenter`) and the in-app
/// `NSSound` path. Mirrors the shape of `AppearanceMode`.
public enum NotificationSound: String, CaseIterable, Identifiable, Codable, Sendable {
  /// Defer to the system: `.default` banner sound and the bundled chime in-app.
  case systemDefault
  /// The bundled `notification.wav` that ships inside the app.
  case chime
  case basso
  case blow
  case bottle
  case frog
  case funk
  case glass
  case hero
  case morse
  case ping
  case pop
  case purr
  case sosumi
  case submarine
  case tink

  public var id: String {
    rawValue
  }

  public var displayName: String {
    switch self {
    case .systemDefault:
      return "System Default"
    case .chime:
      return "Supacode Chime"
    default:
      return systemSoundName ?? rawValue.capitalized
    }
  }

  /// Base name of the `/System/Library/Sounds/<name>.aiff` file backing the
  /// system-sound cases, matching the names `NSSound(named:)` resolves.
  /// `nil` for `.systemDefault` and `.chime`, which are not system sounds.
  /// Package-internal (not `private`) so it has direct unit coverage.
  var systemSoundName: String? {
    switch self {
    case .systemDefault, .chime:
      return nil
    case .basso:
      return "Basso"
    case .blow:
      return "Blow"
    case .bottle:
      return "Bottle"
    case .frog:
      return "Frog"
    case .funk:
      return "Funk"
    case .glass:
      return "Glass"
    case .hero:
      return "Hero"
    case .morse:
      return "Morse"
    case .ping:
      return "Ping"
    case .pop:
      return "Pop"
    case .purr:
      return "Purr"
    case .sosumi:
      return "Sosumi"
    case .submarine:
      return "Submarine"
    case .tink:
      return "Tink"
    }
  }

  /// Sound used on the `UNUserNotificationCenter` (system banner) path.
  ///
  /// NOTE: `UNNotificationSound(named:)` only resolves named sound files from
  /// the app bundle and the app container's `Library/Sounds` directory — it
  /// does NOT search `/System/Library/Sounds`. The macOS system sounds (Funk,
  /// Glass, …) therefore cannot be delivered through the notification banner
  /// and intentionally fall back to `.default` here. Those same names DO
  /// resolve for the in-app `NSSound` path (`makeInAppSound()`); that asymmetry
  /// is by design, not a bug. `.chime` works because `notification.wav` ships
  /// inside the app bundle.
  public var unNotificationSound: UNNotificationSound {
    switch self {
    case .systemDefault:
      return .default
    case .chime:
      return UNNotificationSound(named: UNNotificationSoundName("notification.wav"))
    default:
      return .default
    }
  }

  /// Resolves the `NSSound` used for the in-app (non-banner) notification path.
  ///
  /// - `.systemDefault` and `.chime` both load the bundled `notification.wav`,
  ///   matching the historical in-app behavior (the app has always played the
  ///   bundled chime locally for the in-app sound).
  /// - System sounds resolve by base name through `NSSound(named:)`, which DOES
  ///   search `/System/Library/Sounds`.
  @MainActor
  public func makeInAppSound() -> NSSound? {
    switch self {
    case .systemDefault, .chime:
      guard let url = Bundle.main.url(forResource: "notification", withExtension: "wav") else {
        return nil
      }
      return NSSound(contentsOf: url, byReference: true)
    default:
      guard let name = systemSoundName else { return nil }
      return NSSound(named: name)
    }
  }
}
