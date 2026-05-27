import AppKit
import SupacodeSettingsShared
import SwiftUI

struct ArchivedWorktreeRowView: View {
  let worktree: Worktree
  let pullRequest: GithubPullRequest?
  let customTitle: String?
  let customTint: RepositoryColor?
  let onUnarchive: () -> Void
  let onDelete: () -> Void
  // The system paints selected rows with white-on-blue chrome; the custom tint must yield so the
  // selected row stays readable (matches `SidebarItemView.TitleView`).
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    let display = WorktreePullRequestDisplay(
      worktreeName: worktree.name,
      pullRequest: pullRequest
    )
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    let bodyFontAscender = NSFont.preferredFont(forTextStyle: .body).ascender
    // User override wins; fall back to the branch / folder name on whitespace
    // or nil. Centralised so archive / sidebar / detail can't drift.
    let displayName =
      SidebarDisplayName.resolved(custom: customTitle, fallback: worktree.name)
      ?? worktree.name
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "archivebox")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .frame(width: 16, height: 16)
          .alignmentGuide(.firstTextBaseline) { _ in
            bodyFontAscender
          }
        let titleText = Text(displayName)
          .font(.body)
          .lineLimit(1)
        if let customTint, backgroundProminence != .increased {
          titleText.foregroundStyle(customTint.color)
        } else {
          titleText
        }
        Spacer(minLength: 8)
        HStack(spacing: 8) {
          Button {
            onUnarchive()
          } label: {
            Image(systemName: "tray.and.arrow.up")
              .accessibilityLabel("Unarchive worktree")
          }
          .buttonStyle(.plain)
          .help("Unarchive worktree")
          Button(role: .destructive) {
            onDelete()
          } label: {
            Image(systemName: "trash")
              .accessibilityLabel("Delete worktree")
          }
          .buttonStyle(.plain)
          .help("Delete Worktree (\(deleteShortcut))")
        }
      }
      HStack(spacing: 6) {
        if let createdAt = worktree.createdAt {
          Text("Created \(createdAt, style: .relative)")
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        WorktreePullRequestAccessoryView(display: display)
      }
      .font(.caption)
      .lineLimit(1)
      .frame(minHeight: 14)
      .padding(.leading, 24)
    }
    .frame(height: rowHeight, alignment: .center)
  }

  private var rowHeight: CGFloat {
    50
  }
}
