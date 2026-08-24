import SupacodeSettingsShared
import SwiftUI

/// One capability shown in a settings feature grid: a name and whether the
/// integration surfaces it.
struct FeatureCapability: Identifiable {
  let name: String
  let isSupported: Bool

  var id: String { name }
}

/// Two-column grid of an integration's capabilities, shared by the coding-agent
/// and git-forge settings rows so the two stay identical.
struct FeatureCapabilityGrid: View {
  let capabilities: [FeatureCapability]

  /// `supportedOnly` drops unsupported capabilities entirely (the installed list)
  /// rather than dimming them (the full matrix shown before installing).
  init(capabilities: [FeatureCapability], supportedOnly: Bool = false) {
    self.capabilities = supportedOnly ? capabilities.filter(\.isSupported) : capabilities
  }

  var body: some View {
    // Non-lazy on purpose: the set is small and fixed, and a LazyVGrid inside the
    // settings scroll view drops cells when scrolled off-screen and back.
    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
      ForEach(Array(stride(from: 0, to: capabilities.count, by: 2)), id: \.self) { row in
        GridRow {
          FeatureCapabilityCell(capability: capabilities[row])
          row + 1 < capabilities.count
            ? FeatureCapabilityCell(capability: capabilities[row + 1])
            : nil
        }
      }
    }
    .padding(.top, 4)
  }
}

private struct FeatureCapabilityCell: View {
  let capability: FeatureCapability

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: capability.isSupported ? "checkmark" : "minus")
        .foregroundStyle(capability.isSupported ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        .frame(width: 12)
        .accessibilityLabel(capability.isSupported ? "Supported" : "Not supported")
      Text(capability.name)
        .foregroundStyle(capability.isSupported ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }
    .appFont(.caption)
  }
}
