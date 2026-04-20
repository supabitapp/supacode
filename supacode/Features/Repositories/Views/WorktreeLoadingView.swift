import SwiftUI

struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo
  @Environment(\.surfaceBackgroundOpacity) private var surfaceBackgroundOpacity

  var body: some View {
    let subtitle = subtitleText()
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.large)
      VStack(spacing: 4) {
        Text(info.name)
          .font(.title3)
        if let command = info.progress?.statusCommand {
          Text(command)
            .font(.subheadline)
            .monospaced()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Text(subtitle)
          .font(.subheadline)
          .monospaced()
          .foregroundStyle(.tertiary)
          .lineLimit(5, reservesSpace: true)
          .truncationMode(.head)
          .contentTransition(.opacity)
          .animation(.easeInOut, value: subtitle)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor).opacity(surfaceBackgroundOpacity))
  }

  private func subtitleText() -> String {
    if let progress = info.progress {
      let tail = progress.statusLines.suffix(5)
      guard tail.isEmpty else { return tail.joined(separator: "\n") }
      if let text = progress.statusDetail ?? progress.statusTitle { return text }
    }
    let noun = info.isFolder ? "folder" : "worktree"
    // Folder repositories are their own root — the repository name
    // duplicates the folder name, so skip the "in <name>" suffix.
    if !info.isFolder, let repositoryName = info.repositoryName {
      return "\(info.actionLabel) \(noun) in \(repositoryName)"
    }
    return "\(info.actionLabel) \(noun)…"
  }
}

#Preview("Streaming output") {
  @Previewable @State var statusLines: [String] = []
  WorktreeLoadingView(
    info: WorktreeLoadingInfo(
      name: "sbertix/small-ui-improvements",
      repositoryName: "supacode",
      kind: .creating(
        WorktreeLoadingInfo.Progress(
          statusTitle: "Creating worktree",
          statusDetail: nil,
          statusCommand: "git worktree add",
          statusLines: statusLines
        )
      )
    )
  )
  .frame(width: 600, height: 400)
  .task {
    // Drip lines in so the preview exercises the trailing-lines
    // animation rather than showing a frozen tail.
    let pool = [
      "Preparing worktree (new branch 'sbertix/small-ui-improvements')",
      "Enumerating objects: 1248, done.",
      "Counting objects: 100% (1248/1248), done.",
      "Compressing objects: 100% (512/512), done.",
      "Writing objects: 100% (1248/1248), 3.21 MiB | 5.40 MiB/s, done.",
      "Resolving deltas: 100% (842/842), done.",
      "HEAD is now at c4e9be3 bump v0.8.1",
    ]
    let clock = ContinuousClock()
    for line in pool {
      try? await clock.sleep(for: .milliseconds(600))
      statusLines.append(line)
    }
  }
}
