import AppKit
import SupacodeSettingsShared
import SwiftUI

struct OpenWorktreeActionMenuLabelView: View {
  let action: OpenWorktreeAction

  var body: some View {
    Label {
      Text(action.labelTitle)
    } icon: {
      OpenWorktreeActionIcon(action: action)
    }.labelStyle(.titleAndIcon)
  }
}

/// The icon for an open action (a baked app icon or an SF Symbol). The store is
/// read, never asked to resolve: an unwarmed action renders no icon rather than
/// blocking the menu build on IconServices.
struct OpenWorktreeActionIcon: View {
  let action: OpenWorktreeAction
  @Environment(OpenActionIconStore.self) private var iconStore: OpenActionIconStore?

  var body: some View {
    if let symbolName = action.menuSymbolName {
      // Stays a live symbol so it keeps tracking light / dark.
      Image(systemName: symbolName)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    } else if let icon = iconStore?.icon(for: action) {
      Image(nsImage: icon)
        .renderingMode(.original)
        .accessibilityHidden(true)
    }
  }
}
