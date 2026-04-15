import Sharing
import SupacodeSettingsShared
import SwiftUI

struct PullRequestChecksPopoverButton<Label: View>: View {
  let pullRequest: GithubPullRequest
  @ViewBuilder let label: () -> Label
  @State private var isPresented = false
  @State private var isHoveringButton = false
  @State private var isHoveringPopover = false
  @State private var closeTask: Task<Void, Never>?
  @Environment(\.openURL) private var openURL
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let pullRequestURL = URL(string: pullRequest.url)
    let checks = pullRequest.statusCheckRollup?.checks ?? []
    Button {
      if let pullRequestURL {
        openURL(pullRequestURL)
      }
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .contentShape(.rect)
    .help(
      {
        let overrides = settingsFile.global.shortcutOverrides
        let display = AppShortcuts.openPullRequest.effective(from: overrides)?.display ?? "none"
        return "Open pull request on GitHub (\(display)). Hover to show checks."
      }()
    )
    .accessibilityLabel("Open pull request on GitHub")
    .onHover { hovering in
      isHoveringButton = hovering
      updatePresentation()
    }
    .popover(isPresented: $isPresented) {
      PullRequestChecksPopoverView(
        pullRequest: pullRequest,
        checks: checks
      )
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
