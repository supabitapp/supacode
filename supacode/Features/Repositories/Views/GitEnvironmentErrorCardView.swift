import AppKit
import SwiftUI

/// Non-dismissible sidebar banner shown while the `git` binary is blocked at the
/// environment level (e.g. an unaccepted Xcode license). Explains why repos are
/// missing and offers the remedy command to copy into Terminal.
struct GitEnvironmentErrorCardView: View {
  let error: GitEnvironmentError

  var body: some View {
    SidebarCard(
      content: { GitEnvironmentErrorCardContent(error: error) },
      header: { GitEnvironmentErrorCardIcon() }
    )
  }
}

private struct GitEnvironmentErrorCardIcon: View {
  var body: some View {
    Image(systemName: "exclamationmark.triangle.fill")
      .font(.title2)
      .foregroundStyle(.orange)
      .accessibilityHidden(true)
  }
}

private struct GitEnvironmentErrorCardContent: View {
  let error: GitEnvironmentError

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(error.title)
        .font(.subheadline)
        .fontWeight(.semibold)
      Text(error.message)
        .font(.caption)
        .foregroundStyle(.secondary)
      GitEnvironmentRemedyRow(command: error.remedyCommand)
    }
  }
}

private struct GitEnvironmentRemedyRow: View {
  let command: String

  var body: some View {
    HStack(spacing: 6) {
      Text(command)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .lineLimit(1)
        // Truncate the tail so the leading verb (sudo / xcode-select) stays
        // visible in a narrow sidebar; the copy button carries the full string.
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      CopyCommandButton(command: command)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary, in: .rect(cornerRadius: 6))
  }
}

private struct CopyCommandButton: View {
  let command: String

  var body: some View {
    Button {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(command, forType: .string)
    } label: {
      Image(systemName: "doc.on.doc")
        .font(.caption)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Copy \(command) to the clipboard")
    .accessibilityLabel("Copy command")
  }
}
