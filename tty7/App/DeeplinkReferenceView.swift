import ComposableArchitecture
import SwiftUI

struct DeeplinkReferenceView: View {
  var body: some View {
    Form {
      Section {
        Text(
          // swiftlint:disable:next line_length
          "Each terminal session exposes \(code("TTY7_REPO_ID")), \(code("TTY7_WORKTREE_ID")), \(code("TTY7_TAB_ID")), and \(code("TTY7_SURFACE_ID")) as environment variables. Run \(code("env | grep TTY7_")) to discover the IDs for the current session."
        )
        .foregroundStyle(.secondary)
        Text(
          // swiftlint:disable:next line_length
          "Worktree and repository IDs must be percent-encoded (e.g. `/tmp/repo` → `%2Ftmp%2Frepo`), and \(code("TTY7_REPO_ID")) and \(code("TTY7_WORKTREE_ID")) already are."
        )
        .foregroundStyle(.secondary)
        Text(
          "Deeplinks that run commands or perform destructive actions require confirmation"
            + " unless \"Allow Arbitrary Deeplink Actions\" is enabled in Settings."
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("Deeplink Reference").font(.title.bold())
        Text("Use the \(code("tty7://")) URL scheme to control tty7 from the terminal, scripts, or other apps.")
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
    .init(url: "tty7://", description: "Bring app to front."),
    .init(url: "tty7://help", description: "Open this reference."),
  ]

  private static let worktreeRows: [DeeplinkEntry] = [
    .init(url: "tty7://worktree/<worktree_id>", description: "Select worktree."),
    .init(url: "tty7://worktree/<worktree_id>/run", description: "Run the primary run-kind script."),
    .init(url: "tty7://worktree/<worktree_id>/stop", description: "Stop all run-kind scripts."),
    .init(
      url: "tty7://worktree/<worktree_id>/script/<script_id>/run",
      description: "Run a specific configured script by UUID."
    ),
    .init(
      url: "tty7://worktree/<worktree_id>/script/<script_id>/stop",
      description: "Stop a specific running script by UUID."
    ),
    .init(url: "tty7://worktree/<worktree_id>/archive", description: "Archive the worktree."),
    .init(url: "tty7://worktree/<worktree_id>/unarchive", description: "Unarchive the worktree."),
    .init(url: "tty7://worktree/<worktree_id>/delete", description: "Delete the worktree."),
    .init(url: "tty7://worktree/<worktree_id>/pin", description: "Pin the worktree."),
    .init(url: "tty7://worktree/<worktree_id>/unpin", description: "Unpin the worktree."),
  ]

  private static let tabSurfaceRows: [DeeplinkEntry] = [
    .init(
      url: "tty7://worktree/<worktree_id>/tab/<tab_id>",
      description: "Focus a tab."
    ),
    .init(
      url: "tty7://worktree/<worktree_id>/tab/new",
      description: "Create a new tab.",
      params: "?input=<cmd>&id=<uuid>"
    ),
    .init(
      url: "tty7://worktree/<worktree_id>/tab/<tab_id>/destroy",
      description: "Close a tab."
    ),
    .init(
      url: "tty7://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>",
      description: "Focus a surface.",
      params: "?input=<cmd>"
    ),
    .init(
      url: "tty7://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/split",
      description: "Split a surface. Defaults to horizontal.",
      params: "?direction=horizontal|vertical&input=<cmd>&id=<uuid>"
    ),
    .init(
      url: "tty7://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/destroy",
      description: "Close a surface."
    ),
  ]

  private static let repoRows: [DeeplinkEntry] = [
    .init(url: "tty7://repo/open?path=<absolute-path>", description: "Open a repository."),
    .init(
      url: "tty7://repo/<repo_id>/worktree/new",
      description: "Create a worktree.",
      params: "?branch=<name>&base=<ref>&fetch=true&name=<folder>&location=<dir>"
    ),
  ]

  private static let settingsRows: [DeeplinkEntry] = [
    .init(url: "tty7://settings", description: "Open settings."),
    .init(
      url: "tty7://settings/<section>",
      description: "Open a specific section.",
      params: "general|notifications|worktrees|developer|shortcuts|scripts|updates|github"
    ),
    .init(url: "tty7://settings/repo/<repo_id>", description: "Open repository settings."),
    .init(
      url: "tty7://settings/repo/<repo_id>/scripts",
      description: "Open repository Scripts settings."
    ),
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

// MARK: - Deeplink → window bridge.

/// Opens the deeplink reference window when the reducer sets `isDeeplinkReferenceRequested`.
struct OpenDeeplinkReferenceBridge: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  let store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      .onChange(of: store.isDeeplinkReferenceRequested) { _, requested in
        guard requested else { return }
        openWindow(id: WindowID.deeplinkReference)
        store.send(.deeplinkReferenceOpened)
      }
  }
}

extension View {
  func openDeeplinkReferenceOnRequest(store: StoreOf<AppFeature>) -> some View {
    modifier(OpenDeeplinkReferenceBridge(store: store))
  }
}

/// Inline code fragment styled as primary foreground.
private func code(_ value: String) -> Text {
  Text("`\(value)`").foregroundStyle(.primary)
}
