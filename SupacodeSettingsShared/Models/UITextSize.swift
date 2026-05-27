import SwiftUI

/// Discrete preset mapped to a `DynamicTypeSize` and bound at the root of
/// every Window scene. Constrained to a few useful steps around the macOS
/// default so the Settings UI stays a simple picker rather than a slider
/// across the full 11-value enum (which includes accessibility sizes that
/// aren't appropriate as a general preference knob).
public enum UITextSize: String, CaseIterable, Identifiable, Codable, Sendable {
  case small
  case `default`
  case large
  case larger
  case largest

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .small:
      return "Small"
    case .default:
      return "Default"
    case .large:
      return "Large"
    case .larger:
      return "Larger"
    case .largest:
      return "Largest"
    }
  }

  public var dynamicTypeSize: DynamicTypeSize {
    switch self {
    case .small:
      return .medium
    case .default:
      return .large
    case .large:
      return .xLarge
    case .larger:
      return .xxLarge
    case .largest:
      return .xxxLarge
    }
  }
}
