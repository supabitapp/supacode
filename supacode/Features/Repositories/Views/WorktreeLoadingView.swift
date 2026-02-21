import SwiftUI

struct WorktreeLoadingView: View {
  let info: WorktreeLoadingInfo
  private let bottomAnchorID = "worktree-loading-bottom"
  private var actionLabel: String {
    switch info.state {
    case .creating:
      "Creating"
    case .settingUp:
      "Setting up"
    case .removing:
      "Removing"
    }
  }

  var body: some View {
    let fallbackStatus =
      if let repositoryName = info.repositoryName {
        "\(actionLabel) worktree in \(repositoryName)"
      } else {
        "\(actionLabel) worktree..."
      }
    let statusLine = info.statusDetail ?? info.statusTitle ?? fallbackStatus
    VStack(spacing: 10) {
      ProgressView()
      Text(info.name)
        .font(.headline)
        .multilineTextAlignment(.center)
      if info.statusLines.isEmpty {
        Text(statusLine)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      } else {
        ScrollViewReader { scrollProxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Array(info.statusLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                  .font(.caption)
                  .monospaced()
                  .foregroundStyle(.secondary)
                  .multilineTextAlignment(.leading)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              Color.clear
                .frame(height: 1)
                .id(bottomAnchorID)
            }
            .padding(12)
          }
          .frame(maxWidth: 560, minHeight: 180, maxHeight: 380)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .strokeBorder(.quaternary, lineWidth: 1)
          }
          .onAppear {
            scrollToBottom(using: scrollProxy, animated: false)
          }
          .onChange(of: info.statusLines) { _, _ in
            scrollToBottom(using: scrollProxy, animated: true)
          }
        }
      }
    }
    .frame(maxWidth: 640)
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
    if animated {
      withAnimation(.easeOut(duration: 0.12)) {
        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(bottomAnchorID, anchor: .bottom)
    }
  }
}
