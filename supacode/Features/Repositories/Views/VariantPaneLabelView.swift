import SwiftUI

struct VariantPaneLabelView: View {
  let variant: TaskVariant
  let isFocused: Bool
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    let agent = AgentProvider.byID[variant.agentID]
    let isRunning: Bool = {
      guard let worktreeID = variant.worktreeID else { return false }
      return terminalManager.focusedTaskStatus(for: worktreeID) == .running
    }()
    HStack(spacing: 6) {
      if variant.status == .creatingWorktree {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: agent?.icon ?? "terminal")
          .font(.caption)
          .accessibilityHidden(true)
      }
      Text(agent?.name ?? variant.agentID)
        .font(.caption)
        .fontWeight(.medium)
        .lineLimit(1)
      if isRunning {
        Circle()
          .fill(.green)
          .frame(width: 6, height: 6)
          .accessibilityLabel("Running")
      }
      if variant.status == .failed {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.red)
          .accessibilityLabel("Failed")
      }
      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.bar)
    .overlay(
      Rectangle()
        .frame(height: 2)
        .foregroundStyle(isFocused ? Color.accentColor : Color.clear),
      alignment: .bottom
    )
  }
}
