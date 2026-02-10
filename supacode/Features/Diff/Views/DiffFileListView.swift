import SwiftUI

struct DiffFileListView: View {
  let entries: [GitDiffEntry]
  let selectedPath: String?
  let onSelect: (String) -> Void

  var body: some View {
    List(
      entries,
      selection: Binding(
        get: { selectedPath },
        set: { path in
          if let path { onSelect(path) }
        }
      )
    ) { entry in
      HStack(spacing: 6) {
        statusBadge(for: entry.kind)
          .frame(width: 16)
        Text(entry.path)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if entry.additions > 0 || entry.deletions > 0 {
          HStack(spacing: 2) {
            if entry.additions > 0 {
              Text("+\(entry.additions)")
                .foregroundStyle(.green)
            }
            if entry.deletions > 0 {
              Text("-\(entry.deletions)")
                .foregroundStyle(.red)
            }
          }
          .font(.caption.monospaced())
        }
      }
      .tag(entry.path)
    }
    .listStyle(.plain)
  }

  @ViewBuilder
  private func statusBadge(for kind: GitDiffEntry.Kind) -> some View {
    switch kind {
    case .modified:
      Text("M")
        .font(.caption2.monospaced().bold())
        .foregroundStyle(.orange)
    case .added:
      Text("A")
        .font(.caption2.monospaced().bold())
        .foregroundStyle(.green)
    case .deleted:
      Text("D")
        .font(.caption2.monospaced().bold())
        .foregroundStyle(.red)
    case .renamed:
      Text("R")
        .font(.caption2.monospaced().bold())
        .foregroundStyle(.blue)
    case .untracked:
      Text("?")
        .font(.caption2.monospaced().bold())
        .foregroundStyle(.secondary)
    }
  }
}
