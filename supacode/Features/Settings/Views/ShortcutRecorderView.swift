import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorderView: View {
  let shortcutName: String
  let defaultShortcut: AppShortcut
  @Binding var override: AppShortcutOverride?

  let isRecording: Bool
  let setRecording: (Bool) -> Void

  let warning: String?

  private var isUnbound: Bool {
    override?.isUnbound == true
  }

  private var displayText: String {
    if let override {
      if override.isUnbound { return "—" }
      return override.displayString
    }
    return defaultShortcut.display
  }

  private var displaySymbols: [String] {
    if isUnbound { return ["—"] }
    return displayText.map { String($0) }
  }

  private var isModified: Bool {
    override != nil
  }

  var body: some View {
    HStack(spacing: 6) {
      if isRecording {
        recordingCell
      } else {
        keycapCell
      }
    }
    .contextMenu {
      Button("Change Shortcut…") {
        setRecording(true)
      }
      Divider()
      Button("Unbind") {
        override = .unbound
      }
      .disabled(isUnbound)
      Button("Reset to Default") {
        override = nil
      }
      .disabled(!isModified)
    }
  }

  private var keycapCell: some View {
    HStack(spacing: 3) {
      if isUnbound {
        Text("—")
          .font(.body)
          .foregroundStyle(.tertiary)
          .frame(minWidth: 24, minHeight: 22)
      } else {
        ForEach(Array(displaySymbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isModified ? .primary : .secondary)
            .frame(minWidth: 20, minHeight: 22)
            .background(.quaternary, in: .rect(cornerRadius: 4))
        }
      }

      if let warning {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.yellow)
          .help(warning)
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      setRecording(true)
    }
    .help("Double-click to change. Right-click for more options.")
  }

  private var recordingCell: some View {
    HStack(spacing: 6) {
      Text("Type shortcut…")
        .font(.callout)
        .foregroundStyle(.secondary)

      ShortcutRecorderRepresentable(
        onRecorded: { recorded in
          override = recorded
          setRecording(false)
        },
        onCancelled: {
          setRecording(false)
        }
      )
      .frame(width: 0, height: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
    )
  }
}

// MARK: - NSViewRepresentable

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
  var onRecorded: (AppShortcutOverride) -> Void
  var onCancelled: () -> Void

  func makeNSView(context: Context) -> ShortcutRecorderNSView {
    let view = ShortcutRecorderNSView()
    view.onRecorded = onRecorded
    view.onCancelled = onCancelled
    DispatchQueue.main.async {
      view.window?.makeFirstResponder(view)
    }
    return view
  }

  func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
    nsView.onRecorded = onRecorded
    nsView.onCancelled = onCancelled
  }
}

// MARK: - NSView for key capture

private final class ShortcutRecorderNSView: NSView {
  var onRecorded: ((AppShortcutOverride) -> Void)?
  var onCancelled: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    let keyCode = event.keyCode

    if keyCode == UInt16(kVK_Escape) {
      onCancelled?()
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let modifierOnly = flags.subtracting([.capsLock, .numericPad, .function])
    if modifierOnly.isEmpty {
      return
    }

    var overrideFlags: AppShortcutOverride.ModifierFlags = []
    if flags.contains(.command) { overrideFlags.insert(.command) }
    if flags.contains(.option) { overrideFlags.insert(.option) }
    if flags.contains(.control) { overrideFlags.insert(.control) }
    if flags.contains(.shift) { overrideFlags.insert(.shift) }

    let recorded = AppShortcutOverride(keyCode: keyCode, modifiers: overrideFlags)
    onRecorded?(recorded)
  }

  override func flagsChanged(with event: NSEvent) {
    // Ignore modifier-only presses
  }
}
