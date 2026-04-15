import AppKit
import Carbon.HIToolbox
import SupacodeSettingsShared
import SwiftUI

// Keycap-styled label for a single key symbol.
struct Keycap: View {
  let symbol: String

  var body: some View {
    Text(symbol)
      .font(.body.weight(.medium).monospaced())
      .padding(.horizontal, 6)
      .frame(minWidth: 28, minHeight: 28)
      .background(.quaternary, in: .rect(cornerRadius: 6))
  }
}

// Popover content for recording a hotkey, Raycast-style.
struct HotkeyRecorderPopover: View {
  let onRecorded: (AppShortcutOverride) -> Void
  let onCancelled: () -> Void
  // Returns the display name of the conflicting shortcut, or nil if no conflict.
  let conflictChecker: (AppShortcutOverride) -> String?

  private enum Result {
    case recorded(AppShortcutOverride)
    case conflict(override: AppShortcutOverride, name: String)
  }

  @State private var activeModifiers: AppShortcutOverride.ModifierFlags = []
  @State private var result: Result?
  @State private var shakeOffset: CGFloat = 0
  @State private var dismissTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 8) {
      switch result {
      case .recorded(let override):
        KeycapsView(override: override)
        HStack(spacing: 4) {
          Text("Recorded!")
          Image(systemName: "checkmark.circle.fill")
            .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.green)

      case .conflict(let override, let name):
        KeycapsView(override: override)
        Text("Already used by \(name).")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: true, vertical: false)

      case nil:
        HStack(spacing: 6) {
          if activeModifiers.contains(.control) { Keycap(symbol: "⌃") }
          if activeModifiers.contains(.option) { Keycap(symbol: "⌥") }
          if activeModifiers.contains(.shift) { Keycap(symbol: "⇧") }
          if activeModifiers.contains(.command) { Keycap(symbol: "⌘") }
          if activeModifiers.isEmpty {
            HStack(spacing: 4) {
              Text("e.g.,")
                .foregroundStyle(.tertiary)
              Keycap(symbol: "⇧")
              Keycap(symbol: "⌘")
              Keycap(symbol: "Space")
            }
            .opacity(0.4)
          }
        }
        .frame(minHeight: 28)
        Text("Recording…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .fixedSize()
    .padding(.horizontal, 32)
    .padding(.vertical, 16)
    .offset(x: shakeOffset)
    .overlay(alignment: .topTrailing) {
      if case .recorded = result {
      } else {
        Button {
          onCancelled()
        } label: {
          Image(systemName: "xmark")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Cancel")
        }
        .buttonStyle(.plain)
        .padding(8)
      }
    }
    .background {
      if result == nil {
        HotkeyRecorderRepresentable(
          onRecorded: handleRecorded,
          onCancelled: onCancelled,
          onModifiersChanged: { activeModifiers = $0 }
        )
        .frame(width: 0, height: 0)
      }
    }
  }

  private func handleRecorded(_ override: AppShortcutOverride) {
    dismissTask?.cancel()
    if let name = conflictChecker(override) {
      result = .conflict(override: override, name: name)
      shake()
      dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1500))
        guard !Task.isCancelled else { return }
        result = nil
      }
    } else {
      result = .recorded(override)
      onRecorded(override)
      dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1000))
        guard !Task.isCancelled else { return }
        onCancelled()
      }
    }
  }

  private func shake() {
    withAnimation(.linear(duration: 0.06)) { shakeOffset = -8 }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
      withAnimation(.linear(duration: 0.06)) { shakeOffset = 8 }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      withAnimation(.linear(duration: 0.06)) { shakeOffset = -4 }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      withAnimation(.linear(duration: 0.06)) { shakeOffset = 0 }
    }
  }
}

// MARK: - Keycaps display.

private struct KeycapsView: View {
  let override: AppShortcutOverride

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Array(override.displaySymbols.enumerated()), id: \.offset) { _, symbol in
        Keycap(symbol: symbol)
      }
    }
    .frame(minHeight: 28)
  }
}

// MARK: - NSViewRepresentable for key capture.

private struct HotkeyRecorderRepresentable: NSViewRepresentable {
  var onRecorded: (AppShortcutOverride) -> Void
  var onCancelled: () -> Void
  var onModifiersChanged: (AppShortcutOverride.ModifierFlags) -> Void

  func makeNSView(context: Context) -> HotkeyRecorderNSView {
    let view = HotkeyRecorderNSView()
    view.onRecorded = onRecorded
    view.onCancelled = onCancelled
    view.onModifiersChanged = onModifiersChanged
    return view
  }

  func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
    nsView.onRecorded = onRecorded
    nsView.onCancelled = onCancelled
    nsView.onModifiersChanged = onModifiersChanged
  }
}

// MARK: - NSView for key capture.

final class HotkeyRecorderNSView: NSView {
  var onRecorded: ((AppShortcutOverride) -> Void)?
  var onCancelled: (() -> Void)?
  var onModifiersChanged: ((AppShortcutOverride.ModifierFlags) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  // Intercept all key equivalents to prevent menu shortcuts from firing while recording.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    let keyCode = event.keyCode

    // Escape cancels recording.
    if keyCode == UInt16(kVK_Escape) {
      onCancelled?()
      return
    }

    // Require at least one modifier key.
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let modifierOnly = flags.subtracting([.capsLock, .numericPad, .function])
    guard !modifierOnly.isEmpty else { return }

    var overrideFlags: AppShortcutOverride.ModifierFlags = []
    if flags.contains(.command) { overrideFlags.insert(.command) }
    if flags.contains(.option) { overrideFlags.insert(.option) }
    if flags.contains(.control) { overrideFlags.insert(.control) }
    if flags.contains(.shift) { overrideFlags.insert(.shift) }

    let recorded = AppShortcutOverride(keyCode: keyCode, modifiers: overrideFlags)
    onRecorded?(recorded)
  }

  override func flagsChanged(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var current: AppShortcutOverride.ModifierFlags = []
    if flags.contains(.command) { current.insert(.command) }
    if flags.contains(.option) { current.insert(.option) }
    if flags.contains(.control) { current.insert(.control) }
    if flags.contains(.shift) { current.insert(.shift) }
    onModifiersChanged?(current)
  }
}
