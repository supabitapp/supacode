import AppKit
import SwiftUI

// Checkbox backed by NSButton so it can show a mixed state.
enum CheckboxState: Equatable {
  case checked
  case unchecked
  case mixed
}

struct MixedStateCheckbox: NSViewRepresentable {
  let state: CheckboxState
  // Set on the NSButton itself; SwiftUI accessibility modifiers stop at the representable.
  let accessibilityLabel: String
  let onToggle: (Bool) -> Void

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(
      checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggled(_:)))
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentHuggingPriority(.required, for: .vertical)
    applyState(to: button)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    applyState(to: button)
    context.coordinator.onToggle = onToggle
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onToggle: onToggle)
  }

  private func applyState(to button: NSButton) {
    // Mixed only while shown, so a click never lands on it and the checkbox reads as two-state.
    button.allowsMixedState = state == .mixed
    button.setAccessibilityLabel(accessibilityLabel)
    switch state {
    case .checked: button.state = .on
    case .unchecked: button.state = .off
    case .mixed: button.state = .mixed
    }
  }

  final class Coordinator: NSObject {
    var onToggle: (Bool) -> Void

    init(onToggle: @escaping (Bool) -> Void) {
      self.onToggle = onToggle
    }

    @objc func toggled(_ sender: NSButton) {
      // Clicking mixed or off → on; clicking on → off.
      let newEnabled = sender.state != .off
      onToggle(newEnabled)
    }
  }
}
