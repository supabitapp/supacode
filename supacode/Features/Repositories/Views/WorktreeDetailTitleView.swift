import ComposableArchitecture
import Kingfisher
import SupacodeSettingsShared
import SwiftUI

#if DEBUG
  private nonisolated let titleRenderLogger = SupaLogger("DetailRender")
#endif

enum WorktreeToolbarTitleContent: Hashable, Sendable {
  case git(GitPayload)
  case folder(name: String, tint: RepositoryColor?, hostInfo: String?)

  struct GitPayload: Hashable, Sendable {
    /// Text rendered as the top-line headline. May be the literal branch name or the user's custom
    /// title override; never used for accessibility ("Branch X") since custom titles aren't refs.
    let displayTitle: String
    /// Actual git ref name. Used by accessibility so screen readers announce the real branch.
    let branchName: String
    let repositoryName: String
    let repositoryColor: RepositoryColor?
    let worktreeSubtitle: String?
    let worktreeTint: RepositoryColor?
    let accent: WorktreeAccent
    let rootURL: URL
    /// `[user@]host[:port]` when the repository lives on an SSH host, else nil;
    /// rendered as `· host` plus a `wifi` glyph in the subtitle.
    let hostInfo: String?
  }
}

/// Hosts toolbar item content in an `NSHostingView` pinned to the given
/// scheme's `NSAppearance`. A `.sharedBackgroundVisibility(.hidden)` item host
/// ignores `window.appearance` and follows the app appearance, and a plain
/// `.environment(\.colorScheme, _)` doesn't reach its AppKit-side dynamic color
/// resolution; pinning the hosting view's appearance covers both. When the
/// item is hosted in a borderless toolbar window (fullscreen strip, detached
/// item overlay), the host's content view is pinned too so the bar and its
/// sibling items follow the terminal scheme with it.
struct TerminalSchemeHost<Content: View>: NSViewRepresentable {
  let scheme: ColorScheme
  @ViewBuilder let content: Content

  func makeNSView(context: Context) -> SchemeHostingView<Content> {
    let view = SchemeHostingView(rootView: content)
    view.sizingOptions = .intrinsicContentSize
    view.appearance = NSAppearance(named: Self.appearanceName(for: scheme))
    view.schemeName = Self.appearanceName(for: scheme)
    return view
  }

  func updateNSView(_ nsView: SchemeHostingView<Content>, context: Context) {
    nsView.rootView = content
    // The toolbar re-renders often; only re-pin when the scheme actually flips
    // so unrelated updates don't force an effectiveAppearance re-resolve.
    let name = Self.appearanceName(for: scheme)
    if nsView.appearance?.name != name {
      nsView.appearance = NSAppearance(named: name)
    }
    nsView.schemeName = name
  }

  private static func appearanceName(for scheme: ColorScheme) -> NSAppearance.Name {
    scheme == .light ? .aqua : .darkAqua
  }
}

/// Pins the toolbar host it lands in to the terminal scheme. The main window
/// is left alone (WindowChromeApplier owns its appearance, same value); a
/// borderless host is the toolbar strip or item overlay, whose CONTENT VIEW
/// takes the pin. Never the window property itself: re-pinning the private
/// window makes AppKit rebuild its items, which re-triggers the pin in a loop.
final class SchemeHostingView<Content: View>: NSHostingView<Content> {
  var schemeName: NSAppearance.Name = .aqua {
    didSet {
      guard schemeName != oldValue else { return }
      pinToolbarHostAppearance()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    pinToolbarHostAppearance()
  }

  private func pinToolbarHostAppearance() {
    guard let window, !window.styleMask.contains(.titled) else { return }
    guard let contentView = window.contentView, contentView.appearance?.name != schemeName else {
      return
    }
    contentView.appearance = NSAppearance(named: schemeName)
  }
}

/// Renders the toolbar repo/worktree title. This `.navigation` item carries
/// `.sharedBackgroundVisibility(.hidden)`, whose host ignores
/// `window.appearance`, so `WorktreeToolbarContent` wraps this view in a
/// `TerminalSchemeHost` pinned to the focused terminal's contrast.
/// `.primary` / `.secondary` then match the terminal background like the rest of
/// the window chrome.
struct WorktreeToolbarTitleView: View {
  let content: WorktreeToolbarTitleContent

  var body: some View {
    #if DEBUG
      let _ = Self._printChanges()
      titleRenderLogger.info("WorktreeToolbarTitleView.body re-rendered")
    #endif
    return HStack(spacing: 8) {
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
        case .folder(let name, let tint, let hostInfo):
          HStack(spacing: 4) {
            Text(name)
              .font(.callout.weight(.semibold))
              .foregroundStyle(tint?.color ?? .primary)
              .lineLimit(1)
              .truncationMode(.middle)
            if let hostInfo {
              Image(systemName: "wifi")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .help(hostInfo)
                .accessibilityHidden(true)
            }
          }
        case .git(let payload):
          Text(payload.displayTitle)
            .font(.callout.weight(.semibold))
            .foregroundStyle(payload.worktreeTint?.color ?? .primary)
            .lineLimit(1)
            .truncationMode(.middle)
          let repoText = Text(payload.repositoryName)
            .foregroundStyle(payload.repositoryColor?.color ?? .secondary)
          let accentStyle = AnyShapeStyle(payload.accent.shapeStyle(emphasized: false))
          let trail: Text? = payload.worktreeSubtitle.map { worktreeSubtitle in
            Text("\(Text(" · ").foregroundStyle(.secondary))\(Text(worktreeSubtitle).foregroundStyle(accentStyle))")
          }
          HStack(spacing: 0) {
            repoText
            if let hostInfo = payload.hostInfo {
              Image(systemName: "wifi")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .help(hostInfo)
                .accessibilityHidden(true)
                .padding(.leading, 3)
            }
            if let trail {
              trail
            }
          }
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
    case .folder(let name, _, _):
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
      WorktreeToolbarTitleView(
        content: .git(
          .init(
            displayTitle: "sbertix/319-toolbar-details",
            branchName: "sbertix/319-toolbar-details",
            repositoryName: "supacode",
            repositoryColor: .blue,
            worktreeSubtitle: "319-toolbar-details",
            worktreeTint: nil,
            accent: .pinned,
            rootURL: supacodeRepoRoot,
            hostInfo: nil
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
            displayTitle: "main",
            branchName: "main",
            repositoryName: "supacode",
            repositoryColor: .blue,
            worktreeSubtitle: "Default",
            worktreeTint: nil,
            accent: .main,
            rootURL: URL(fileURLWithPath: "/tmp/preview"),
            hostInfo: nil
          )
        )
      )
    }
  }.frame(width: 600, height: 600)
}

#Preview("Folder") {
  Text("").toolbar {
    ToolbarItem {
      WorktreeToolbarTitleView(
        content: .folder(name: "Documents", tint: nil, hostInfo: nil))
    }
  }.frame(width: 600, height: 600)
}
