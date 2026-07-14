import SupacodeSettingsShared
import SwiftUI

/// One card in the Dock/menu-bar visibility picker, mirroring `AppearanceOptionCardView`.
struct AppVisibilityOptionCardView: View {
  let visibility: AppVisibility
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(visibility.imageName)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .clipShape(.rect(cornerRadius: 8))
          .accessibilityLabel(visibility.title)
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(
                isSelected ? Color.accentColor : .clear,
                lineWidth: 2
              )
          }
        Text(visibility.title)
          .font(.callout)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .foregroundStyle(isSelected ? .primary : .secondary)
      }
    }
    .buttonStyle(.plain)
    .help(visibility.help)
  }
}
