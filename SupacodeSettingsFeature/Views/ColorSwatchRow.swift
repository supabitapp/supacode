import AppKit
import SupacodeSettingsShared
import SwiftUI

/// Predefined palette + Default + Custom hex picker, shared between repo customization and per-script overrides.
public struct ColorSwatchRow: View {
  @Binding var color: RepositoryColor?

  public init(color: Binding<RepositoryColor?>) {
    _color = color
  }

  // Only panel-driven drags route through `set`; predefined / Default clicks set `color` directly.
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
        // Diagonal stroke avoids doubling the SF Symbol's circle outline.
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
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .help(color.displayName)
  }
}

private struct CustomSwatchButton: View {
  let isSelected: Bool
  @Binding var color: Color

  var body: some View {
    // Hidden `ColorPicker` opens the system color panel on click; the visible circle is purely decorative.
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
    }
    .modifier(SwatchSelectionRing(isSelected: isSelected))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Custom")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
  // Closes the shared color panel so the singleton doesn't outlive this view.
  // `public` is required: `supacode` (RepositoryCustomizationView) consumes this across module boundaries.
  public func dismissSystemColorPanelOnDisappear() -> some View {
    onDisappear { NSColorPanel.shared.orderOut(nil) }
  }
}
