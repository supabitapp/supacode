import SupacodeSettingsShared
import SwiftUI

/// Small system-styled tag marking a setting as Beta.
public struct BetaBadge: View {
  public init() {}

  public var body: some View {
    CapsuleBadge("Beta")
  }
}

/// A small system-styled capsule tag. Uses `.quaternary` fill so it tracks the
/// theme and never introduces a custom color.
struct CapsuleBadge: View {
  let label: String

  init(_ label: String) {
    self.label = label
  }

  var body: some View {
    Text(label)
      .appFont(.caption2, weight: .semibold)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.quaternary, in: .capsule)
  }
}
