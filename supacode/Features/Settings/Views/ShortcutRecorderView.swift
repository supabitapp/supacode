import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorderView: View {
  let shortcutName: String
  let defaultShortcut: AppShortcut
  @Binding var override: AppShortcutOverride?
  var existingOverrides: [String: AppShortcutOverride]
  var allDefaults: [AppShortcut]

  @State private var isRecording = false
  @State private var conflictWarning: String?

  private var displayText: String {
    if let override {
      return override.displayString
    }
    return defaultShortcut.display
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(isRecording ? "Press shortcut..." : displayText)
          .font(.body.monospaced())
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
          )

        if isRecording {
          ShortcutRecorderRepresentable(
            onRecorded: { recorded in
              handleRecorded(recorded)
            },
            onCancelled: {
              isRecording = false
            }
          )
          .frame(width: 0, height: 0)
        }

        Button(isRecording ? "Cancel" : "Record") {
          if isRecording {
            isRecording = false
          } else {
            conflictWarning = nil
            isRecording = true
          }
        }
        .help(isRecording ? "Cancel recording" : "Record a new shortcut")

        if override != nil {
          Button("Reset") {
            override = nil
            conflictWarning = nil
          }
          .help("Reset to default shortcut")
        }
      }

      if let conflictWarning {
        Text(conflictWarning)
          .font(.callout)
          .foregroundStyle(.yellow)
      }
    }
  }

  private func handleRecorded(_ recorded: AppShortcutOverride) {
    isRecording = false
    conflictWarning = nil

    if let warning = reservedWarning(for: recorded) {
      conflictWarning = warning
    }

    if let conflict = conflictingShortcut(for: recorded) {
      let existing = conflictWarning.map { $0 + "\n" } ?? ""
      conflictWarning = existing + conflict
    }

    override = recorded
  }

  private func reservedWarning(for shortcut: AppShortcutOverride) -> String? {
    let reserved: [(keyCode: Int, modifiers: AppShortcutOverride.ModifierFlags, label: String)] = [
      (kVK_ANSI_Q, .command, "⌘Q"),
      (kVK_ANSI_W, .command, "⌘W"),
      (kVK_ANSI_H, .command, "⌘H"),
      (kVK_ANSI_M, .command, "⌘M"),
      (kVK_Space, .command, "⌘Space"),
      (kVK_Tab, .command, "⌘Tab"),
    ]
    for entry in reserved
    where shortcut.keyCode == UInt16(entry.keyCode) && shortcut.modifiers == entry.modifiers {
      return "\(entry.label) is reserved by the system"
    }
    return nil
  }

  private func conflictingShortcut(for shortcut: AppShortcutOverride) -> String? {
    for (name, existing) in existingOverrides where name != shortcutName {
      if existing.keyCode == shortcut.keyCode && existing.modifiers == shortcut.modifiers {
        let label = allDefaults.first { $0.name == name }
        let displayName = label?.name ?? name
        return "Conflicts with \(displayName) (\(existing.displayString))"
      }
    }

    for def in allDefaults where def.name != shortcutName {
      if existingOverrides[def.name] != nil { continue }
      let defDisplay = def.display
      let newDisplay = shortcut.displayString
      if defDisplay == newDisplay {
        return "Conflicts with \(def.name) (\(defDisplay))"
      }
    }

    return nil
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
