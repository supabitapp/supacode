import SwiftUI

struct NotificationPopoverButton<Label: View>: View {
  let notifications: [WorktreeTerminalNotification]
  @ViewBuilder let label: () -> Label
  @State private var isPresented = false
  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var closeTask: Task<Void, Never>?

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .contentShape(.rect)
    .help("Unread notifications. Hover to show.")
    .accessibilityLabel("Unread notifications")
    .onHover { hovering in
      isHoveringButton = hovering
      updatePresentation()
    }
    .popover(isPresented: $isPresented) {
      NotificationPopoverView(notifications: notifications)
        .onHover { hovering in
          isHoveringPopover = hovering
          updatePresentation()
        }
        .onDisappear {
          isHoveringPopover = false
          updatePresentation()
        }
    }
    .onDisappear {
      closeTask?.cancel()
    }
  }

  private func updatePresentation() {
    if isHoveringButton || isHoveringPopover {
      closeTask?.cancel()
      isPresented = true
      return
    }
    closeTask?.cancel()
    closeTask = Task { @MainActor in
      try? await ContinuousClock().sleep(for: .milliseconds(150))
      if !Task.isCancelled {
        isPresented = false
      }
    }
  }
}
