import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Pinned / Active highlight section renderer. Receives an already-ordered
/// render plan (rows grouped by repository and branch, or by custom folder) from
/// `SidebarStructure` and just lays it out; no per-leaf classification or sort runs here.
struct SidebarHighlightSection: View {
  let kind: SidebarStructure.HighlightKind
  let rows: [SidebarStructure.HighlightRow]
  let store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag]
  /// Hint string to render in the row's trailing slot, keyed by `Worktree.ID`.
  /// Empty when Cmd isn't pressed; the caller builds it once for the whole
  /// composed hotkey order.
  let shortcutHintByID: [Worktree.ID: String]

  var body: some View {
    Section {
      ForEach(rows) { row in
        switch row {
        case .repository(let repositoryID, let name, let isCollapsed, let leafDescendantIDs):
          SidebarPathGroupHeaderRow(
            prefix: name,
            components: [],
            depth: 0,
            isCollapsed: isCollapsed,
            leafDescendantIDs: leafDescendantIDs,
            store: store
          ) {
            store.send(
              .highlightGroupExpansionChanged(
                kind: kind, repositoryID: repositoryID, prefix: nil, isExpanded: isCollapsed))
          }
        case .nested(.leaf(let rowID, let depth, let displayName), let repositoryID):
          SidebarHighlightRow(
            rowID: rowID,
            store: store,
            terminalManager: terminalManager,
            repositoryHighlightByID: repositoryHighlightByID,
            shortcutHint: shortcutHintByID[rowID],
            nestDepth: depth,
            displayNameOverride: displayName,
            // Under a repository header, the header already names the repository.
            showsRepository: repositoryID == nil
          )
        case .nested(
          .groupHeader(let prefix, let components, let depth, let isCollapsed, let leafDescendantIDs),
          let repositoryID
        ):
          SidebarPathGroupHeaderRow(
            prefix: prefix,
            components: components,
            depth: depth,
            isCollapsed: isCollapsed,
            leafDescendantIDs: leafDescendantIDs,
            store: store
          ) {
            if let repositoryID {
              store.send(
                .highlightGroupExpansionChanged(
                  kind: kind, repositoryID: repositoryID, prefix: prefix, isExpanded: isCollapsed))
            } else {
              store.send(.sidebarGroupExpansionChanged(path: prefix, isExpanded: isCollapsed))
            }
          }
        }
      }
    } header: {
      HStack(spacing: 4) {
        Text(kind.title)
        SidebarHighlightHeaderDot(color: kind.indicatorColor)
      }
      .appFontInheriting(.subheadline, weight: .semibold)
    }
  }
}

extension SidebarStructure.HighlightKind {
  var indicatorColor: Color {
    switch self {
    case .pinned: .orange
    case .active: .blue
    }
  }
}

/// Colored dot shown after a highlight section title and reused after each
/// bucket label in the per-repo hoist summary line.
struct SidebarHighlightHeaderDot: View {
  let color: Color
  @Environment(\.pixelLength) private var pixelLength

  var body: some View {
    Circle()
      .fill(color.opacity(0.6))
      .overlay(Circle().stroke(color, lineWidth: pixelLength))
      .frame(width: 6, height: 6)
      .accessibilityHidden(true)
  }
}

/// Single highlight-section row. Resolves its repo identity via per-leaf
/// scope so observation stays bounded to the leaf, then forwards into
/// `SidebarItemRow` for the actual draw. Extracted as a struct so each row
/// gets its own SwiftUI identity (per "view subviews as structs").
private struct SidebarHighlightRow: View {
  let rowID: SidebarItemID
  @Bindable var store: StoreOf<RepositoriesFeature>
  let terminalManager: WorktreeTerminalManager
  let repositoryHighlightByID: [Repository.ID: SidebarHighlightRepoTag]
  let shortcutHint: String?
  let nestDepth: Int
  let displayNameOverride: String?
  let showsRepository: Bool

  var body: some View {
    let highlight =
      showsRepository
      ? store.scope(state: \.sidebarItems[id: rowID], action: \.sidebarItems[id: rowID])
        .flatMap { repositoryHighlightByID[$0.state.repositoryID] }
      : nil
    SidebarItemRow(
      rowID: rowID,
      store: store,
      terminalManager: terminalManager,
      isRepositoryRemoving: false,
      hideSubtitle: false,
      moveMode: .alwaysDisabled,
      shortcutHint: shortcutHint,
      displayNameOverride: displayNameOverride,
      nestDepth: nestDepth,
      highlightSubtitle: highlight
    )
  }
}
