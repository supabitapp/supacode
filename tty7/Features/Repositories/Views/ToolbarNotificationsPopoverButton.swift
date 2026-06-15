import SwiftUI

struct ToolbarNotificationsPopoverButton: View {
  let groups: [ToolbarNotificationRepositoryGroup]
  let unseenWorktreeCount: Int
  let onSelectNotification: (Worktree.ID, WorktreeTerminalNotification) -> Void
  let onDismissAll: () -> Void
  @State private var isPresented = false
  @State private var isPinnedOpen = false
  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var closeTask: Task<Void, Never>?

  private var notificationCount: Int {
    groups.reduce(0) { count, repository in
      count
        + repository.worktrees.reduce(0) { worktreeCount, worktree in
          worktreeCount + worktree.notifications.filter { !$0.isRead }.count
        }
    }
  }

  var body: some View {
    Button {
      togglePresentation()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: unseenWorktreeCount > 0 ? "bell.badge.fill" : "bell.fill")
          .foregroundStyle(unseenWorktreeCount > 0 ? .orange : .secondary)
          .accessibilityHidden(true)
        if notificationCount > 0 {
          Text(notificationCount, format: .number)
            .font(.caption.monospacedDigit())
        }
      }
    }
    .help("Notifications. Hover or click to show all notifications.")
    .accessibilityLabel("Notifications")
    .onHover { hovering in
      isHoveringButton = hovering
      updatePresentation()
    }
    .popover(isPresented: $isPresented) {
      ToolbarNotificationsPopoverView(
        groups: groups,
        onSelectNotification: { worktreeID, notification in
          onSelectNotification(worktreeID, notification)
          closePopover()
        },
        onDismissAll: {
          onDismissAll()
          closePopover()
        }
      )
      .onHover { hovering in
        isHoveringPopover = hovering
        updatePresentation()
      }
      .onDisappear {
        isHoveringPopover = false
        isPinnedOpen = false
      }
    }
    .onChange(of: groups) { _, newValue in
      if newValue.isEmpty {
        closePopover()
      }
    }
    .onDisappear {
      closeTask?.cancel()
    }
  }

  private func togglePresentation() {
    if isPinnedOpen {
      closePopover()
      return
    }
    closeTask?.cancel()
    isPinnedOpen = true
    isPresented = true
  }

  private func updatePresentation() {
    if isPinnedOpen || isHoveringButton || isHoveringPopover {
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

  private func closePopover() {
    closeTask?.cancel()
    isPinnedOpen = false
    isPresented = false
  }
}
