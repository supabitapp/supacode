import AppKit
import ComposableArchitecture
import SwiftUI

struct RepositoryCustomizationView: View {
  @Bindable var store: StoreOf<RepositoryCustomizationFeature>
  @FocusState private var isTitleFocused: Bool

  var body: some View {
    Form {
      Section {
        TextField("Title", text: $store.title, prompt: Text(store.defaultName))
          .focused($isTitleFocused)
          .onSubmit {
            store.send(.saveButtonTapped)
          }
        LabeledContent("Color") {
          ColorSwatchRowView(store: store)
        }
      } header: {
        Text("Customize Repository")
        Text("Override the sidebar title and tint for `\(store.defaultName)`.")
      }
      .headerProminence(.increased)
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Save") {
          store.send(.saveButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Save (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 420)
    .task { isTitleFocused = true }
    .onDisappear {
      // The system color panel is a singleton (`NSColorPanel.shared`)
      // and stays visible after the sheet is dismissed, so close it
      // explicitly. Without this it persists, can outlive the
      // sheet, and macOS window restoration may even bring it back
      // on next launch with no main window in sight.
      NSColorPanel.shared.orderOut(nil)
    }
  }
}

private struct ColorSwatchRowView: View {
  @Bindable var store: StoreOf<RepositoryCustomizationFeature>

  var body: some View {
    HStack(spacing: 8) {
      DefaultSwatchButton(
        isSelected: store.color == nil,
        action: { store.send(.selectColor(nil)) }
      )
      ForEach(RepositoryColor.predefined, id: \.rawValue) { color in
        ColorSwatchButton(
          color: color,
          isSelected: store.color == color,
          action: { store.send(.selectColor(color)) }
        )
      }
      Divider()
        .frame(height: 18)
        .padding(.horizontal, 2)
      CustomSwatchButton(
        isSelected: store.color?.isCustom == true,
        color: $store.customColor,
      )
    }
  }
}

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
    .help(color.displayName)
  }
}

private struct CustomSwatchButton: View {
  let isSelected: Bool
  @Binding var color: Color

  var body: some View {
    // Visible swatch is a circular rainbow gradient with the
    // current pick layered on top so the user can see what's
    // selected. The system `ColorPicker` sits underneath at the
    // same frame, with `labelsHidden` and near-zero opacity, so a
    // click anywhere on the swatch opens the macOS color panel
    // without exposing the rounded-rectangle picker chrome.
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
