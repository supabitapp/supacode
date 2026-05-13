import SwiftUI

/// Borderless icon-button menu chrome for toolbars and tab bars — no chevron, plain background,
/// secondary tint.
struct SecondaryToolbarMenuStyle: MenuStyle {
  func makeBody(configuration: Configuration) -> some View {
    Menu(configuration)
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
  }
}

extension MenuStyle where Self == SecondaryToolbarMenuStyle {
  static var secondaryToolbar: SecondaryToolbarMenuStyle { .init() }
}
