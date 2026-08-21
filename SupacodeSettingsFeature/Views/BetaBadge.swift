import SupacodeSettingsShared
import SwiftUI

/// Compact tinted "Beta" pill, matching the File Explorer card's.
public struct BetaBadge: View {
  public init() {}

  public var body: some View {
    Text("Beta")
      .appFont(.caption2, weight: .semibold)
      .foregroundStyle(.indigo)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.indigo.opacity(0.15), in: .capsule)
      .accessibilityLabel("Beta")
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
