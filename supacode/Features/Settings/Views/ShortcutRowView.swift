import SupacodeSettingsShared
import SwiftUI

// Self-contained hotkey cell with local recording state for Table compatibility.
struct HotkeyCellView: View {
  let shortcut: AppShortcut
  let override: AppShortcutOverride?
  let isEnabled: Bool
  let warning: String?
  let onRecorded: (AppShortcutOverride) -> Void
  let onReset: () -> Void
  // Returns the display name of the conflicting shortcut, or nil.
  let conflictChecker: (AppShortcutOverride) -> String?

  @State private var isRecording = false

  private var display: String {
    override.map(\.displayString) ?? shortcut.display
  }

  var body: some View {
    if isEnabled {
      let isModified = override != nil
      Button {
        isRecording = true
      } label: {
        HStack(spacing: 4) {
          Text(display)
            .foregroundStyle(isModified ? .primary : .secondary)
          if let warning {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundStyle(.yellow)
              .accessibilityLabel("Warning")
              .help(warning)
          }
          Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .popover(isPresented: $isRecording) {
        HotkeyRecorderPopover(
          onRecorded: { newOverride in
            onRecorded(newOverride)
          },
          onCancelled: { isRecording = false },
          conflictChecker: conflictChecker
        )
      }
      .contextMenu {
        Button("Change Shortcut…") {
          isRecording = true
        }
        Divider()
        Button("Reset to Default") {
          onReset()
        }
        .disabled(!isModified)
      }
    } else {
      Text("--")
        .foregroundStyle(.tertiary)
    }
  }
}
