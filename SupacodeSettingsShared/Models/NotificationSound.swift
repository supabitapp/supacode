import Foundation

/// User-selectable in-app notification sound; only drives the in-app `NSSound`
/// path (system notifications play the macOS banner's own sound). The String
/// raw value is the persisted contract, so renaming a case orphans selections.
public enum NotificationSound: String, CaseIterable, Identifiable, Codable, Sendable {
  /// No sound plays in-app.
  case never
  // `/System/Library/Sounds`.
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
  /// The bundled Supacode chime.
  case supacodeClassic

  /// How a choice resolves to an in-app sound, or `nil` when nothing plays.
  /// Exactly one kind per case, so invalid combinations are unrepresentable.
  /// `NotificationSoundClient` turns it into an `NSSound`, keeping this model
  /// free of AppKit.
  enum Source: Equatable, Sendable {
    case system(name: String)
    case bundled(resource: String, withExtension: String)
  }

  var source: Source? {
    switch self {
    case .never:
      return nil
    case .basso:
      return .system(name: "Basso")
    case .blow:
      return .system(name: "Blow")
    case .bottle:
      return .system(name: "Bottle")
    case .frog:
      return .system(name: "Frog")
    case .funk:
      return .system(name: "Funk")
    case .glass:
      return .system(name: "Glass")
    case .hero:
      return .system(name: "Hero")
    case .morse:
      return .system(name: "Morse")
    case .ping:
      return .system(name: "Ping")
    case .pop:
      return .system(name: "Pop")
    case .purr:
      return .system(name: "Purr")
    case .sosumi:
      return .system(name: "Sosumi")
    case .submarine:
      return .system(name: "Submarine")
    case .tink:
      return .system(name: "Tink")
    case .supacodeClassic:
      return .bundled(resource: "notification", withExtension: "wav")
    }
  }

  /// The `/System/Library/Sounds` cases (every case whose source is `.system`).
  public static let systemCases: [NotificationSound] = allCases.filter {
    if case .system? = $0.source { return true }
    return false
  }

  public var id: String {
    rawValue
  }

  public var displayName: String {
    switch self {
    case .never:
      return "Never"
    case .supacodeClassic:
      return "Supacode Classic"
    default:
      if case .system(let name)? = source { return name }
      return rawValue.capitalized
    }
  }
}
