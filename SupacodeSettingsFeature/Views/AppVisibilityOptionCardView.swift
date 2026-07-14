import SupacodeSettingsShared
import SwiftUI

/// One card in the Dock/menu-bar visibility picker, mirroring
/// `AppearanceOptionCardView`. Uses an SF Symbol placeholder until dedicated
/// artwork lands.
struct AppVisibilityOptionCardView: View {
  let visibility: AppVisibility
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        RoundedRectangle(cornerRadius: 8)
          .fill(.quaternary)
          .aspectRatio(1.6, contentMode: .fit)
          .overlay {
            Image(systemName: visibility.symbolName)
              .font(.system(size: 22))
              .foregroundStyle(isSelected ? Color.accentColor : .secondary)
          }
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(
                isSelected ? Color.accentColor : .clear,
                lineWidth: 2
              )
          }
          .accessibilityLabel(visibility.title)
        Text(visibility.title)
          .font(.callout)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
    }
    .buttonStyle(.plain)
  }
}
