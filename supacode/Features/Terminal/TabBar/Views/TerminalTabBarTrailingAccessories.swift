import SwiftUI

struct TerminalTabBarTrailingAccessories: View {
  let createTab: () -> Void
  let splitHorizontally: () -> Void
  let splitVertically: () -> Void
  let canSplit: Bool

  @Environment(GhosttyShortcutManager.self)
  private var ghosttyShortcuts
  @Environment(CommandKeyObserver.self)
  private var commandKeyObserver

  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var isHoverPopoverPresented = false
  @State private var openTask: Task<Void, Never>?
  @State private var closeTask: Task<Void, Never>?

  var body: some View {
    Button {
      createTab()
      isHoverPopoverPresented = false
    } label: {
      if commandKeyObserver.isPressed {
        HStack(spacing: TerminalTabBarMetrics.contentSpacing) {
          Text("New Tab")
            .font(.caption)
          if let shortcut = ghosttyShortcuts.display(for: "new_tab") {
            ShortcutHintView(text: shortcut, color: TerminalTabBarColors.inactiveText)
          }
        }
      } else {
        Label("New Tab", systemImage: "plus")
          .labelStyle(.iconOnly)
      }
    }
    .buttonStyle(.borderless)
    .help(helpText("New Tab", shortcut: ghosttyShortcuts.display(for: "new_tab")))
    .onHover { hovering in
      isHoveringButton = hovering
      updateHoverPopoverVisibility()
    }
    .popover(
      isPresented: $isHoverPopoverPresented,
      attachmentAnchor: .point(.bottom),
      arrowEdge: .bottom
    ) {
      hoverPopoverContent
        .onHover { hovering in
          isHoveringPopover = hovering
          updateHoverPopoverVisibility()
        }
        .onDisappear {
          isHoveringPopover = false
          updateHoverPopoverVisibility()
        }
    }
    .frame(height: TerminalTabBarMetrics.barHeight)
    .padding(.trailing, 8)
  }

  private var hoverPopoverContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        createTab()
        isHoverPopoverPresented = false
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "plus")
            .accessibilityHidden(true)
          Text("New Tab")
          Spacer(minLength: 0)
          if let shortcut = ghosttyShortcuts.display(for: "new_tab") {
            ShortcutHintView(text: shortcut, color: TerminalTabBarColors.inactiveText)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(helpText("New Tab", shortcut: ghosttyShortcuts.display(for: "new_tab")))

      Divider()

      Button {
        splitVertically()
        isHoverPopoverPresented = false
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "rectangle.righthalf.inset.filled")
            .accessibilityHidden(true)
          Text("Split Vertically")
          Spacer(minLength: 0)
          if let shortcut = ghosttyShortcuts.display(for: "new_split:right") {
            ShortcutHintView(text: shortcut, color: TerminalTabBarColors.inactiveText)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(helpText("Split Vertically", shortcut: ghosttyShortcuts.display(for: "new_split:right")))
      .disabled(!canSplit)

      Button {
        splitHorizontally()
        isHoverPopoverPresented = false
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "rectangle.bottomhalf.inset.filled")
            .accessibilityHidden(true)
          Text("Split Horizontally")
          Spacer(minLength: 0)
          if let shortcut = ghosttyShortcuts.display(for: "new_split:down") {
            ShortcutHintView(text: shortcut, color: TerminalTabBarColors.inactiveText)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(helpText("Split Horizontally", shortcut: ghosttyShortcuts.display(for: "new_split:down")))
      .disabled(!canSplit)
    }
    .padding(10)
    .frame(minWidth: 220)
  }

  private func helpText(_ title: String, shortcut: String?) -> String {
    guard let shortcut else { return title }
    return "\(title) (\(shortcut))"
  }

  private func updateHoverPopoverVisibility() {
    let isHoveringAny = isHoveringButton || isHoveringPopover
    if isHoveringAny {
      closeTask?.cancel()
      closeTask = nil

      guard !isHoverPopoverPresented else { return }
      openTask?.cancel()
      openTask = Task { @MainActor in
        // Intentional delay so clicks on + don't get interrupted by the hover UI.
        try? await Task.sleep(for: .milliseconds(350))
        guard isHoveringButton || isHoveringPopover else { return }
        // Prevent showing while the user is in the middle of a click-drag/click-hold.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        isHoverPopoverPresented = true
      }
    } else {
      openTask?.cancel()
      openTask = nil

      guard isHoverPopoverPresented else { return }
      closeTask?.cancel()
      closeTask = Task { @MainActor in
        // Allow time to move from button into popover without it flashing closed.
        try? await Task.sleep(for: .milliseconds(350))
        guard !(isHoveringButton || isHoveringPopover) else { return }
        isHoverPopoverPresented = false
      }
    }
  }
}
