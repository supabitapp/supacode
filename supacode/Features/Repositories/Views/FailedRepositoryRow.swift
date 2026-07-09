import AppKit
import SupacodeSettingsShared
import SwiftUI

struct FailedRepositoryRow: View {
  let name: String
  let path: String
  let removeRepository: () -> Void

  var body: some View {
    Label {
      Text(name)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .fontWeight(.semibold)
        .foregroundStyle(.pink)
        .frame(width: 16, height: 16)
        .accessibilityLabel("Repository unavailable")
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
    .contextMenu {
      Button("Copy as Pathname", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
      }
      Divider()
      Button(
        "Remove Repository…",
        systemImage: "folder.badge.minus",
        role: .destructive,
        action: removeRepository
      )
      .help("Remove this repository from Supacode. Files on disk are untouched.")
    }
  }
}

/// Informational warning row for a git repo whose worktrees can't be listed
/// while git is environment-blocked. Not a failure: no remove action, and the
/// row isn't selectable (the bottom banner carries the remedy).
struct EnvironmentBlockedRepositoryRow: View {
  let name: String
  let path: String
  let removeRepository: () -> Void

  var body: some View {
    Label {
      Text(name)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .fontWeight(.semibold)
        .foregroundStyle(.orange)
        .frame(width: 16, height: 16)
        .accessibilityLabel("Git unavailable")
    }
    .labelStyle(.verticallyCentered)
    .listRowInsets(.trailing, 4)
    .listRowInsets(.vertical, 6)
    .help(
      "Git is unavailable right now, so this repository's worktrees can't be listed. "
        + "See the banner below to restore it."
    )
    .contextMenu {
      Button("Copy as Pathname", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
      }
      Divider()
      // Reachable while blocked so a mistaken add isn't a dead-end until git recovers.
      Button(
        "Remove Repository…",
        systemImage: "folder.badge.minus",
        role: .destructive,
        action: removeRepository
      )
      .help("Remove this repository from Supacode. Files on disk are untouched.")
    }
  }
}
