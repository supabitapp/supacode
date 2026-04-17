import AppKit
import SupacodeSettingsShared
import SwiftUI

struct OpenWorktreeActionMenuLabelView: View {
  let action: OpenWorktreeAction
  let shortcutHint: String?

  private func resizedIcon(_ image: NSImage, size: CGSize) -> NSImage {
    let newImage = NSImage(size: size)
    newImage.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: 1.0
    )
    newImage.unlockFocus()
    return newImage
  }

  var body: some View {
    Label {
      if let shortcutHint {
        Text(shortcutHint)
      } else {
        Text(action.labelTitle)
      }
    } icon: {
      if let icon = action.menuIcon {
        switch icon {
        case .app(let image):
          Image(nsImage: resizedIcon(image, size: CGSize(width: 16, height: 16)))
            .renderingMode(.original)
            .accessibilityHidden(true)
        case .symbol(let name):
          Image(systemName: name)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
        }
      }
    }.labelStyle(.titleAndIcon)
  }
}
