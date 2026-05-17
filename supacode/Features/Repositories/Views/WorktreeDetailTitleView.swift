import ComposableArchitecture
import Kingfisher
import SupacodeSettingsShared
import SwiftUI

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

/// Wraps `WorktreeToolbarTitleBody` with a chrome-aware `\.colorScheme`
/// override. The toolbar lives outside the `windowTintColorScheme` modifier
/// (which wraps `detailContent`'s body only — see
/// `WorktreeDetailView.detailContent`), so the chrome env doesn't reach here.
/// This wrapper tracks the same dependencies as `WindowTintColorScheme`
/// (system scheme + `ghosttyRuntimeConfigDidChange`) and resolves
/// `\.colorScheme` against the live chrome so the title text stays readable
/// when the Ghostty theme diverges from the system theme (e.g. light system
/// + dark terminal background, or the "Supacode Terminal Theme" toggle
/// flipping between sync-on and sync-off).
struct WorktreeToolbarTitleView: View {
  let content: WorktreeToolbarTitleContent
  let terminalManager: WorktreeTerminalManager

  @Environment(\.colorScheme) private var systemColorScheme
  @State private var configReloadCounter = 0

  var body: some View {
    _ = configReloadCounter
    _ = systemColorScheme
    let tintScheme = terminalManager.surfaceBackgroundColorScheme()
    let appearance = SurfaceChromeAppearance(
      colorScheme: tintScheme,
      systemColorScheme: systemColorScheme
    )
    return WorktreeToolbarTitleBody(content: content)
      .environment(\.surfaceChromeAppearance, appearance)
      .environment(\.colorScheme, tintScheme)
      .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
        configReloadCounter &+= 1
      }
  }
}

private struct WorktreeToolbarTitleBody: View {
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
      WorktreeToolbarTitleBody(
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
      WorktreeToolbarTitleBody(
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
      WorktreeToolbarTitleBody(content: .folder(name: "Documents"))
    }
  }.frame(width: 600, height: 600)
}
