import AppKit
import SupacodeSettingsShared
import SwiftUI

/// Reusable color picker row: predefined palette + Default + Custom hex.
/// Used by repository sidebar customization and per-script color overrides.
public struct ColorSwatchRow: View {
  @Binding var color: RepositoryColor?

  public init(color: Binding<RepositoryColor?>) {
    _color = color
  }

  /// View-driven drags only — predefined / Default clicks bypass `set` so they
  /// don't quantize to `.custom(hex)`. A panel drag onto a predefined hue is
  /// intentionally captured as `.custom(hex)`.
  private var customColorBinding: Binding<Color> {
    Binding(
      get: { color?.color ?? .accentColor },
      set: { newValue in
        guard let custom = RepositoryColor.custom(from: newValue) else { return }
        color = custom
      }
    )
  }

  public var body: some View {
    HStack(spacing: 8) {
      DefaultSwatchButton(
        isSelected: color == nil,
        action: { color = nil }
      )
      ForEach(RepositoryColor.predefined, id: \.rawValue) { swatch in
        ColorSwatchButton(
          color: swatch,
          isSelected: color == swatch,
          action: { color = swatch }
        )
      }
      Divider()
        .frame(height: 18)
        .padding(.horizontal, 2)
      CustomSwatchButton(
        isSelected: color?.isCustom == true,
        color: customColorBinding,
      )
    }
  }
}

// MARK: - Swatch atoms.

private struct DefaultSwatchButton: View {
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .strokeBorder(.secondary, lineWidth: 1)
          .background(Circle().fill(.background))
        // Single diagonal stroke reads as "no tint" without doubling
        // up the circle outline the SF Symbol would draw.
        Path { path in
          path.move(to: CGPoint(x: 4, y: 20))
          path.addLine(to: CGPoint(x: 20, y: 4))
        }
        .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      }
      .frame(width: 24, height: 24)
      .modifier(SwatchSelectionRing(isSelected: isSelected))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Default")
    .help("Default")
  }
}

private struct ColorSwatchButton: View {
  let color: RepositoryColor
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(color.color)
        .frame(width: 24, height: 24)
        .modifier(SwatchSelectionRing(isSelected: isSelected))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(color.displayName)
    .help(color.displayName)
  }
}

private struct CustomSwatchButton: View {
  let isSelected: Bool
  @Binding var color: Color

  var body: some View {
    // Rainbow gradient + current pick on top, with a near-invisible system
    // ColorPicker beneath the same frame so a click opens the macOS color
    // panel without exposing the picker's rounded-rectangle chrome.
    ZStack {
      ColorPicker("Custom Color", selection: $color, supportsOpacity: false)
        .labelsHidden()
        .opacity(0.02)
        .frame(width: 24, height: 24)
      Circle()
        .fill(
          AngularGradient(
            colors: [.red, .yellow, .green, .blue, .purple, .red],
            center: .center,
          )
        )
        .overlay {
          Circle()
            .fill(color)
            .padding(7)
        }
        .frame(width: 24, height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .modifier(SwatchSelectionRing(isSelected: isSelected))
    .accessibilityLabel("Custom")
    .help("Custom")
  }
}

private struct SwatchSelectionRing: ViewModifier {
  let isSelected: Bool

  func body(content: Content) -> some View {
    content
      .overlay {
        Circle()
          .stroke(.tint, lineWidth: 2)
          .padding(-3)
          .opacity(isSelected ? 1 : 0)
      }
      .animation(.easeOut(duration: 0.15), value: isSelected)
  }
}

extension View {
  /// Closes `NSColorPanel.shared` when this view disappears. Apply to settings
  /// panes that embed `ColorSwatchRow` so the singleton system panel doesn't
  /// outlive a page change, sheet dismissal, or window close.
  public func dismissSystemColorPanelOnDisappear() -> some View {
    onDisappear { NSColorPanel.shared.orderOut(nil) }
  }
}
