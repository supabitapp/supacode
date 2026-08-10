import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct DeeplinkReferenceView: View {
  var body: some View {
    Form {
      Section {
        Text(
          // swiftlint:disable:next line_length
          "Each terminal session still exposes \(code("SUPACODE_REPO_ID")), \(code("SUPACODE_WORKTREE_ID")), \(code("SUPACODE_TAB_ID")), and \(code("SUPACODE_SURFACE_ID")), but these id variables are deprecated and will be removed in the next release, along with the surface routes. Prefer the \(code("supacode")) CLI, whose pane / tab commands resolve the focused target for you. Only \(code("SUPACODE_SOCKET_PATH")) is non-deprecated."
        )
        .foregroundStyle(.secondary)
        Text(
          // swiftlint:disable:next line_length
          "Worktree and repository IDs must be percent-encoded (e.g. `/tmp/repo` → `%2Ftmp%2Frepo`), and \(code("SUPACODE_REPO_ID")) and \(code("SUPACODE_WORKTREE_ID")) already are."
        )
        .foregroundStyle(.secondary)
        Text(
          "Deeplinks that run commands or perform destructive actions require confirmation"
            + " unless \"Allow dangerous actions\" permits them in Developer settings."
        )
        .foregroundStyle(.secondary)
        Text(
          // swiftlint:disable:next line_length
          "Any worktree action, and \(code("repo/<repo_id>/worktree/new")), accepts \(code("background=true")) to leave the sidebar selection and keyboard focus untouched. New tabs and splits then stay in the background instead of becoming active."
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("Deeplink Reference").appFont(.title, weight: .bold)
        Text("Use the \(code("supacode://")) URL scheme to control Supacode from the terminal, scripts, or other apps.")
      }

      DeeplinkSection(title: "General", rows: Self.generalRows)
      DeeplinkSection(title: "Worktree Actions", rows: Self.worktreeRows)
      DeeplinkSection(title: "Tab", rows: Self.tabRows)
      DeeplinkSection(title: "Pane", rows: Self.paneRows)
      DeeplinkSection(title: "Surface (deprecated)", rows: Self.surfaceRows)
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
    .init(url: "supacode://worktree/<worktree_id>/run", description: "Run the primary run-kind script."),
    .init(url: "supacode://worktree/<worktree_id>/stop", description: "Stop all run-kind scripts."),
    .init(
      url: "supacode://worktree/<worktree_id>/script/<script_id>/run",
      description: "Run a specific configured script by UUID."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/script/<script_id>/stop",
      description: "Stop a specific running script by UUID."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/archive",
      description: "Archive the worktree. Targeting the current worktree closes its terminals."
    ),
    .init(url: "supacode://worktree/<worktree_id>/unarchive", description: "Unarchive the worktree."),
    .init(
      url: "supacode://worktree/<worktree_id>/delete",
      description: "Delete the worktree. Targeting the current worktree closes its terminals."
    ),
    .init(url: "supacode://worktree/<worktree_id>/pin", description: "Pin the worktree."),
    .init(url: "supacode://worktree/<worktree_id>/unpin", description: "Unpin the worktree."),
    .init(
      url: "supacode://worktree/<worktree_id>/appearance",
      description: "Update title/tint overrides. Omitted fields are preserved; empty title clears; color=none clears.",
      params: "?title=<title>&color=<red|orange|yellow|green|teal|blue|purple|%23RRGGBB[AA]|none>"
    ),
  ]

  private static let tabRows: [DeeplinkEntry] = [
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>",
      description: "Focus a tab."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/new",
      description: "Create a new tab; pane= anchors it in a pane (a pane, tab, or content id).",
      params: "?input=<cmd>&id=<uuid>&title=<title>&pane=<pane_token>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/rename?title=<title>",
      description: "Set the persistent title override; an empty title clears it."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/move",
      description: "Move a tab into a new split neighboring its pane.",
      params: "?direction=left|right|up|down"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/destroy",
      description: "Close a tab."
    ),
  ]

  private static let paneRows: [DeeplinkEntry] = [
    .init(
      url: "supacode://worktree/<worktree_id>/pane/<pane_id>",
      description: "Focus a pane by id."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/pane/focus",
      description: "Move focus to a neighboring pane.",
      params: "?direction=left|right|up|down"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/pane/<token>/split",
      description: "Split a pane. token is a pane, tab, or content id. Defaults to horizontal.",
      params: "?direction=horizontal|vertical&input=<cmd>&id=<uuid>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/pane/<token>/destroy",
      description: "Close a pane and all its tabs."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/pane/<token>/zoom",
      description: "Toggle a pane's zoom."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/pane/<token>/window",
      description: "Toggle a pane's window mode."
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/pane/equalize",
      description: "Equalize every split ratio."
    ),
  ]

  private static let surfaceRows: [DeeplinkEntry] = [
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>",
      description: "Deprecated (focus a surface). Use tab focus.",
      params: "?input=<cmd>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/split",
      description: "Deprecated. Use pane split.",
      params: "?direction=horizontal|vertical&input=<cmd>&id=<uuid>"
    ),
    .init(
      url: "supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/destroy",
      description: "Deprecated (close a surface). Use tab destroy."
    ),
  ]

  private static let repoRows: [DeeplinkEntry] = [
    .init(url: "supacode://repo/open?path=<absolute-path>", description: "Open a repository."),
    .init(
      url: "supacode://repo/<repo_id>/worktree/new",
      description:
        "Create a worktree. upstream=<ref> sets the new branch's tracking branch, an empty upstream= clears it. "
        + "pin=true applies to local repositories only.",
      params: "?branch=<name>&base=<ref>&upstream=<ref>&fetch=true&name=<folder>&location=<dir>&pin=true"
    ),
  ]

  private static let settingsRows: [DeeplinkEntry] = [
    .init(url: "supacode://settings", description: "Open settings."),
    .init(
      url: "supacode://settings/<section>",
      description: "Open a specific section.",
      params: "general|accessibility|notifications|worktrees|developer|shortcuts|scripts|updates|github"
    ),
    .init(url: "supacode://settings/repo/<repo_id>", description: "Open repository settings."),
    .init(
      url: "supacode://settings/repo/<repo_id>/scripts",
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

  var descriptionText: Text {
    guard let params else { return Text(description) }
    return Text("\(description) Optional: \(code(params)).")
  }
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
              .appFont(.body, monospaced: true)
              .gridColumnAlignment(.leading)
            row.descriptionText
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
