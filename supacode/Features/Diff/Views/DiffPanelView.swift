import ComposableArchitecture
import SwiftUI

struct DiffPanelView: View {
  @Bindable var store: StoreOf<DiffFeature>
  let diffState: WorktreeDiffState?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let diffState {
        if diffState.entries.isEmpty && !diffState.isLoading {
          emptyState
        } else {
          content(diffState: diffState)
        }
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  private var header: some View {
    HStack {
      Text("Changes")
        .font(.headline)
      if let diffState, !diffState.entries.isEmpty {
        Text("\(diffState.entries.count)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let diffState, diffState.isLoading {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "checkmark.circle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .accessibilityLabel("No changes")
      Text("No changes")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func content(diffState: WorktreeDiffState) -> some View {
    VSplitView {
      DiffFileListView(
        entries: diffState.entries,
        selectedPath: store.selectedFilePath,
        onSelect: { path in store.send(.selectFile(path)) }
      )
      .frame(minHeight: 100, idealHeight: 160)

      DiffTextView(
        attributedDiff: diffState.attributedDiff,
        scrollToFileOffset: fileOffset(for: store.selectedFilePath, in: diffState)
      )
      .frame(minHeight: 100)
    }
  }

  private func fileOffset(for path: String?, in diffState: WorktreeDiffState) -> Int? {
    guard let path, let attributed = diffState.attributedDiff else { return nil }
    let searchString = "diff --git a/\(path)"
    let nsString = attributed.string as NSString
    let range = nsString.range(of: searchString)
    return range.location != NSNotFound ? range.location : nil
  }
}
