import ComposableArchitecture
import SwiftUI

struct DeeplinkCheatsheetView: View {
  var body: some View {
    Form {
      Section {
        Text(
          // swiftlint:disable:next line_length
          "Each terminal session exposes \(code("SUPACODE_REPO_ID")), \(code("SUPACODE_WORKTREE_ID")), \(code("SUPACODE_TAB_ID")), and \(code("SUPACODE_SURFACE_ID")) as environment variables. Run \(code("env | grep SUPACODE_")) to discover the IDs for the current session."
        )
        .foregroundStyle(.secondary)
        Text(
          // swiftlint:disable:next line_length
          "Worktree and repository IDs must be percent-encoded (e.g. `/tmp/repo` → `%2Ftmp%2Frepo`), and \(code("SUPACODE_REPO_ID")) and \(code("SUPACODE_WORKTREE_ID")) already are."
        )
        .foregroundStyle(.secondary)
        Text(
          "Deeplinks that run commands or perform destructive actions require confirmation"
            + " unless \"Allow Arbitrary Deeplink Actions\" is enabled in Settings."
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("Deeplink Reference").font(.title.bold())
        Text("Use the \(code("supacode://")) URL scheme to control Supacode from the terminal, scripts, or other apps.")
      }

      DeeplinkSection(title: "General", rows: Self.generalRows)
      DeeplinkSection(title: "Worktree Actions", rows: Self.worktreeRows)
      DeeplinkSection(title: "Tab & Surface", rows: Self.tabSurfaceRows)
      DeeplinkSection(title: "Repository", rows: Self.repoRows)
      DeeplinkSection(title: "Settings", rows: Self.settingsRows)
    }
    .textSelection(.enabled)
    .formStyle(.grouped)
    .frame(minWidth: 300)
    .navigationTitle("")
  }

  // MARK: - Row data.

  private static let generalRows: [DeeplinkEntry] = [
    .init(url: "supacode://", description: "Bring app to front."),
    .init(url: "supacode://help", description: "Open this reference."),
  ]

  private static let worktreeRows: [DeeplinkEntry] = [
    .init(url: "supacode://worktree/<worktree_id>", description: "Select worktree."),
    .init(url: "supacode://worktree/<worktree_id>/run", description: "Run the worktree script."),
    .init(url: "supacode://worktree/<worktree_id>/stop", description: "Stop the running script."),
    .init(url: "supacode://worktree/<worktree_id>/archive", description: "Archive the worktree."),
    .init(url: "supacode://worktree/<worktree_id>/unarchive", description: "Unarchive the worktree."),
    .init(url: "supacode://worktree/<worktree_id>/delete", description: "Delete the worktree."),
    .init(url: "supacode://worktree/<worktree_id>/pin", description: "Pin the worktree."),
    .init(url: "supacode://worktree/<worktree_id>/unpin", description: "Unpin the worktree."),
  ]

  private static let tabSurfaceRows: [DeeplinkEntry] = [
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>",
      description: "Focus a tab."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/new",
      description: "Create a new tab.",
      params: "?input=<cmd>&id=<uuid>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/destroy",
      description: "Close a tab."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>",
      description: "Focus a surface.",
      params: "?input=<cmd>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/split",
      description: "Split a surface. Defaults to horizontal.",
      params: "?direction=horizontal|vertical&input=<cmd>&id=<uuid>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/destroy",
      description: "Close a surface."
    ),
  ]

  private static let repoRows: [DeeplinkEntry] = [
    .init(url: "supacode://repo/open?path=<absolute-path>", description: "Open a repository."),
    .init(
      url: "supacode://repo/<repo_id>/worktree/new",
      description: "Create a worktree.",
      params: "?branch=<name>&base=<ref>&fetch=true"
    ),
  ]

  private static let settingsRows: [DeeplinkEntry] = [
    .init(url: "supacode://settings", description: "Open settings."),
    .init(
      url: "supacode://settings/<section>",
      description: "Open a specific section.",
      params: "general|notifications|worktrees|codingAgents|shortcuts|updates|github"
    ),
    .init(url: "supacode://settings/repo/<repo_id>", description: "Open repository settings."),
  ]
}

// MARK: - Components.

private struct DeeplinkEntry: Identifiable {
  let id = UUID()
  let url: String
  let description: String
  var params: String?
}

private struct DeeplinkSection: View {
  let title: String
  let rows: [DeeplinkEntry]

  var body: some View {
    Section(title) {
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
        ForEach(rows) { row in
          GridRow {
            Text(row.url)
              .font(.body.monospaced())
              .gridColumnAlignment(.leading)
            Group {
              if let params = row.params {
                Text("\(row.description) Optional: \(code(params)).")
              } else {
                Text(row.description)
              }
            }
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
          }
        }
      }
    }
  }
}

struct DeeplinkCheatsheetMenuButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Deeplink Reference") {
      openWindow(id: WindowID.deeplinkCheatsheet)
    }
    .help("Open the deeplink cheatsheet.")
  }
}

// MARK: - Deeplink → window bridge.

/// Opens the deeplink cheatsheet window when the reducer sets `isDeeplinkCheatsheetRequested`.
struct OpenDeeplinkCheatsheetBridge: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  let store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .onChange(of: store.isDeeplinkCheatsheetRequested) { _, requested in
        guard requested else { return }
        openWindow(id: WindowID.deeplinkCheatsheet)
        store.send(.deeplinkCheatsheetOpened)
      }
  }
}

extension View {
  func openDeeplinkCheatsheetOnRequest(store: StoreOf<AppFeature>) -> some View {
    modifier(OpenDeeplinkCheatsheetBridge(store: store))
  }
}

/// Inline code fragment styled as primary foreground.
private func code(_ value: String) -> Text {
  Text("`\(value)`").foregroundStyle(.primary)
}
