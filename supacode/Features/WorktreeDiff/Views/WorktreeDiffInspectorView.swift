import ComposableArchitecture
import SwiftUI

struct WorktreeDiffInspectorView: View {
  @Bindable var store: StoreOf<WorktreeDiffFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
  }

  private var header: some View {
    let active = store.activeWorktree
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Changes")
          .font(.headline)
        Spacer(minLength: 0)
        Button {
          store.send(.refreshActiveWorktree)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help("Refresh Changes")
        .accessibilityLabel("Refresh Changes")
        .disabled(active == nil)
      }
      Text(active?.rootURL.path(percentEncoded: false) ?? "No worktree selected")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var content: some View {
    if let active = store.activeWorktree,
      let worktreeState = store.worktrees[active.id]
    {
      VSplitView {
        changesList(worktreeID: active.id, state: worktreeState)
          .frame(minHeight: 140)
        diffView(state: worktreeState)
      }
    } else {
      Text("Select a worktree to view changes.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  @ViewBuilder
  private func changesList(
    worktreeID: Worktree.ID,
    state: WorktreeDiffFeature.WorktreeState
  ) -> some View {
    if let error = state.entriesError, !error.isEmpty {
      Text(error)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if state.entries.isEmpty {
      if state.isLoadingEntries {
        VStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
      } else {
        Text("Working tree clean")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    } else {
      let selection = Binding<String?>(
        get: { state.selectedPath },
        set: { store.send(.setSelectedPath(worktreeID, $0)) }
      )

      List(selection: selection) {
        ForEach(state.entries) { entry in
          HStack(spacing: 8) {
            StatusBadge(kind: entry.kind)
            Text(entry.displayPath)
              .font(.body.monospaced())
              .lineLimit(1)
            Spacer(minLength: 0)
            Text(entry.statusCode)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .tag(entry.path)
        }
      }
      .listStyle(.sidebar)
      .overlay(alignment: .topTrailing) {
        if state.isLoadingEntries {
          ProgressView()
            .controlSize(.small)
            .padding(8)
        }
      }
    }
  }

  @ViewBuilder
  private func diffView(state: WorktreeDiffFeature.WorktreeState) -> some View {
    if state.selectedPath == nil {
      Text("Select a file to view the diff.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if state.diff.isLoading {
      VStack {
        Spacer()
        ProgressView()
          .controlSize(.small)
        Spacer()
      }
    } else if let error = state.diff.error, !error.isEmpty {
      Text(error)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if state.diff.document.text.isEmpty {
      Text("No diff")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      DiffTextView(
        revision: state.diff.document.revision,
        text: state.diff.document.text
      )
    }
  }
}

private struct StatusBadge: View {
  let kind: GitDiffKind

  var body: some View {
    Text(label)
      .font(.caption2)
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(color.opacity(0.18)))
  }

  private var label: String {
    switch kind {
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .copied: return "C"
    case .untracked: return "?"
    case .conflicted: return "U"
    case .modified: return "M"
    case .unknown: return "?"
    }
  }

  private var color: Color {
    switch kind {
    case .added: return .green
    case .deleted: return .red
    case .renamed: return .blue
    case .copied: return .blue
    case .untracked: return .orange
    case .conflicted: return .yellow
    case .modified: return .secondary
    case .unknown: return .secondary
    }
  }
}
