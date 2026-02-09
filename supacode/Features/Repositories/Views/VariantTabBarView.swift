import ComposableArchitecture
import SwiftUI

struct VariantTabBarView: View {
  let task: CodingTask
  let selectedVariantID: TaskVariant.ID?
  let onSelect: (TaskVariant.ID) -> Void
  let terminalManager: WorktreeTerminalManager

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(task.variants) { variant in
          variantTab(variant)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
    .background(.bar)
  }

  @ViewBuilder
  private func variantTab(_ variant: TaskVariant) -> some View {
    let isSelected = variant.id == selectedVariantID
    let agent = AgentProvider.byID[variant.agentID]
    let isRunning: Bool = {
      guard let worktreeID = variant.worktreeID else { return false }
      return terminalManager.focusedTaskStatus(for: worktreeID) == .running
    }()
    Button {
      onSelect(variant.id)
    } label: {
      HStack(spacing: 6) {
        if variant.status == .creatingWorktree {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: agent?.icon ?? "terminal")
            .font(.caption)
        }
        Text(agent?.name ?? variant.agentID)
          .font(.caption)
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
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .help(variant.branchName)
  }
}
