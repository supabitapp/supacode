import SwiftUI

/// A macOS 13.0+ compatible alternative to `.glassEffect(.regular, in: .rect(cornerRadius:))`
/// (macOS 16.0+). On macOS 16.0+, delegates to the native modifier. On macOS 13–15, falls
/// back to `.visualEffect` with a regular material blended within the window, clipped to the
/// specified corner radius.
struct GlassEffectCompat: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    if #available(macOS 16.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    } else {
      content
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
  }
}

extension View {
  /// Applies a glass-effect with the given corner radius, compatible with macOS 13.0+.
  func glassEffectCompat(cornerRadius: CGFloat) -> some View {
    modifier(GlassEffectCompat(cornerRadius: cornerRadius))
  }
}
