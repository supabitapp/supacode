import Foundation

/// The user's preferred UI language.
///
/// Applied by writing the `AppleLanguages` array into `UserDefaults`; because
/// AppKit resolves the bundle's localization once at process start, a change
/// only takes effect after the app relaunches. `.system` clears the override so
/// the app follows the macOS language order.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case english
  case simplifiedChinese

  public var id: String { rawValue }

  /// The `AppleLanguages` override this choice writes, or `nil` to follow the
  /// system (which clears any existing override).
  public var appleLanguagesOverride: [String]? {
    switch self {
    case .system: nil
    case .english: ["en"]
    case .simplifiedChinese: ["zh-Hans"]
    }
  }

  /// `UserDefaults` key persisting the choice across launches.
  public static let storageKey = "preferredLanguage"
  /// The system key that actually drives bundle localization resolution.
  private static let appleLanguagesKey = "AppleLanguages"

  /// Reads the persisted choice, defaulting to `.system`.
  public static func current(_ defaults: UserDefaults = .standard) -> AppLanguage {
    guard let raw = defaults.string(forKey: storageKey), let language = AppLanguage(rawValue: raw)
    else { return .system }
    return language
  }

  /// Persists the choice and writes the matching `AppleLanguages` override (or
  /// clears it for `.system`). Takes effect on the next launch.
  public static func apply(_ language: AppLanguage, to defaults: UserDefaults = .standard) {
    defaults.set(language.rawValue, forKey: storageKey)
    if let override = language.appleLanguagesOverride {
      defaults.set(override, forKey: appleLanguagesKey)
    } else {
      defaults.removeObject(forKey: appleLanguagesKey)
    }
  }

  /// Re-applies the persisted choice at launch so `AppleLanguages` stays in
  /// sync even if it was cleared externally.
  public static func syncAtLaunch(_ defaults: UserDefaults = .standard) {
    apply(current(defaults), to: defaults)
  }
}
