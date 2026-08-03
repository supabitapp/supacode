import Foundation

public nonisolated struct CustomNotificationSound: Codable, Equatable, Hashable, Sendable {
  public let displayName: String
  public let fileName: String

  public init(displayName: String, fileName: String) {
    self.displayName = displayName
    self.fileName = fileName
  }
}

/// User-selectable notification sound. The String raw value is the persisted
/// contract, so renaming a case orphans selections.
public nonisolated enum NotificationSound: String, CaseIterable, Identifiable, Codable, Hashable,
  Sendable
{
  /// No sound plays.
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
  /// A user-provided sound copied into `Library/Sounds`.
  case custom

  enum Source: Equatable, Sendable {
    case system(name: String)
    case bundled(resource: String, withExtension: String)
    case custom(fileName: String)
  }

  func source(customSound: CustomNotificationSound?) -> Source? {
    switch self {
    case .never:
      return nil
    case .supacodeClassic:
      return .bundled(resource: "notification", withExtension: "wav")
    case .custom:
      guard let customSound else { return nil }
      return .custom(fileName: customSound.fileName)
    default:
      return .system(name: rawValue.capitalized)
    }
  }

  public static let systemCases = allCases.filter {
    if case .system = $0.source(customSound: nil) {
      return true
    }
    return false
  }

  public var usesSelectedSoundForSystemNotifications: Bool {
    self == .supacodeClassic || self == .custom
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
    case .custom:
      return "Custom"
    default:
      return rawValue.capitalized
    }
  }
}

public nonisolated struct NotificationSoundConfiguration: Equatable, Hashable, Sendable {
  public let sound: NotificationSound
  public let customSound: CustomNotificationSound?

  public init(sound: NotificationSound, customSound: CustomNotificationSound?) {
    self.sound = sound
    self.customSound = customSound
  }

  var source: NotificationSound.Source? {
    sound.source(customSound: customSound)
  }
}
