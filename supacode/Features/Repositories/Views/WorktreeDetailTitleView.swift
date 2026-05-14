import ComposableArchitecture
import Kingfisher
import SupacodeSettingsShared
import SwiftUI

/// Title block in the worktree detail toolbar. The `.git` case carries the avatar plus
/// branch / repo / worktree composition; `.folder` is the simpler single-line label.
enum WorktreeToolbarTitleContent: Hashable, Sendable {
  case git(GitPayload)
  case folder(name: String)

  struct GitPayload: Hashable, Sendable {
    let branchName: String
    let repositoryName: String
    let repositoryColor: RepositoryColor?
    let worktreeSubtitle: String?
    let accent: WorktreeAccent
    let rootURL: URL
  }
}

/// Toolbar title block: repo avatar (or folder glyph) + branch name (main focus) above
/// a "repo · worktree" caption whose worktree segment uses the same main / pinned tint
/// as the sidebar.
struct WorktreeToolbarTitleView: View {
  let content: WorktreeToolbarTitleContent

  var body: some View {
    HStack(spacing: 8) {
      Group {
        switch content {
        case .folder:
          Image(systemName: "folder")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(3)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        case .git(let payload):
          RepositoryOwnerAvatar(rootURL: payload.rootURL)
        }
      }
      .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 0) {
        switch content {
        case .folder(let name):
          Text(name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
        case .git(let payload):
          Text(payload.branchName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          let repoText = Text(payload.repositoryName)
            .foregroundStyle(payload.repositoryColor?.color ?? .secondary)
          let line: Text =
            if let worktreeSubtitle = payload.worktreeSubtitle {
              repoText
                + Text(" · ").foregroundStyle(.secondary)
                + Text(worktreeSubtitle).foregroundStyle(payload.accent.shapeStyle(emphasized: false))
            } else {
              repoText
            }
          line
            .font(.footnote)
            .lineLimit(1)
        }
      }
    }
    .frame(maxWidth: 320, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    switch content {
    case .folder(let name):
      return "Folder \(name)"
    case .git(let payload):
      let suffix = payload.worktreeSubtitle.map { ", worktree \($0)" } ?? ""
      return "Branch \(payload.branchName) in \(payload.repositoryName)\(suffix)"
    }
  }
}

/// Falls back to a branch glyph while loading or when the remote doesn't resolve to a
/// GitHub owner. Routes through `GitClientDependency` so previews / tests can mock the
/// avatar lookup.
private struct RepositoryOwnerAvatar: View {
  let rootURL: URL
  @State private var avatarURL: URL?
  @Dependency(GitClientDependency.self) private var gitClient

  var body: some View {
    KFImage(avatarURL)
      .placeholder {
        Image(systemName: "arrow.trianglehead.branch")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .padding(2)
          .accessibilityHidden(true)
      }
      .resizable()
      .aspectRatio(1, contentMode: .fit)
      .frame(width: 22, height: 22)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .shadow(radius: 1, y: 0.5)
      .accessibilityHidden(true)
      .task(id: rootURL) {
        avatarURL = await GitHubOwnerAvatar.url(for: rootURL, gitClient: gitClient)
      }
  }
}

/// Shared resolver for GitHub owner avatars, used by both the toolbar title and the
/// settings sidebar's repository label.
enum GitHubOwnerAvatar {
  static func url(for rootURL: URL, gitClient: GitClientDependency) async -> URL? {
    guard let info = await gitClient.remoteInfo(rootURL) else { return nil }
    return URL(string: "https://github.com/\(info.owner).png?size=64")
  }
}

#Preview("Git worktree") {
  let supacodeRepoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  Text("").toolbar {
    ToolbarItem {
      WorktreeToolbarTitleView(
        content: .git(
          .init(
            branchName: "sbertix/319-toolbar-details",
            repositoryName: "supacode",
            repositoryColor: .blue,
            worktreeSubtitle: "319-toolbar-details",
            accent: .pinned,
            rootURL: supacodeRepoRoot
          )
        )
      )
    }
  }.frame(width: 600, height: 600)
}

#Preview("Main worktree") {
  Text("").toolbar {
    ToolbarItem {
      WorktreeToolbarTitleView(
        content: .git(
          .init(
            branchName: "main",
            repositoryName: "supacode",
            repositoryColor: .blue,
            worktreeSubtitle: "Default",
            accent: .main,
            rootURL: URL(fileURLWithPath: "/tmp/preview")
          )
        )
      )
    }
  }.frame(width: 600, height: 600)
}

#Preview("Folder") {
  Text("").toolbar {
    ToolbarItem {
      WorktreeToolbarTitleView(content: .folder(name: "Documents"))
    }
  }.frame(width: 600, height: 600)
}
