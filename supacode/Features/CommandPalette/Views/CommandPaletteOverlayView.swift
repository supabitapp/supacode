import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import SwiftUI

struct CommandPaletteOverlayView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  let items: [CommandPaletteItem]
  @FocusState private var isQueryFocused: Bool
  @State private var hoveredID: CommandPaletteItem.ID?
  @State private var filteredItems: [CommandPaletteItem] = []

  var body: some View {
    // The card fills the glass panel edge to edge; positioning, the material
    // background, corner rounding, and click-away dismissal are all owned by
    // `CommandPalettePanel`, not this view.
    CommandPaletteCard(
      query: $store.query,
      selectedIndex: $store.selectedIndex,
      items: filteredItems,
      placeholder: queryPlaceholder,
      hoveredID: $hoveredID,
      isQueryFocused: _isQueryFocused,
      onEvent: { event in
        switch event {
        case .exit:
          store.send(.setPresented(false))
        case .submit:
          submitSelected(rows: filteredItems)
        case .move(let direction):
          moveSelection(direction, rows: filteredItems)
        }
      },
      activate: { id in
        activate(id, rows: filteredItems)
      }
    )
    .task {
      isQueryFocused = true
      let updatedItems = refreshFilteredItems(items: items)
      updateSelection(rows: updatedItems)
    }
    .onChange(of: store.query) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      resetSelection(rows: updatedItems)
    }
    .onChange(of: items) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      updateSelection(rows: updatedItems)
    }
    .onChange(of: store.recencyByItemID) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      updateSelection(rows: updatedItems)
    }
  }

  private func updateSelection(rows: [CommandPaletteItem]) {
    store.send(
      .updateSelection(
        itemsCount: rows.count,
        defaultIndex: CommandPaletteFeature.defaultSelectionIndex(rows: rows, query: store.query)
      )
    )
  }

  private func resetSelection(rows: [CommandPaletteItem]) {
    store.send(
      .resetSelection(
        itemsCount: rows.count,
        defaultIndex: CommandPaletteFeature.defaultSelectionIndex(rows: rows, query: store.query)
      )
    )
  }

  /// Query-field placeholder, matched to the active surface. The worktree
  /// switcher (⌘P) only navigates to worktrees; the full command palette (⌘⇧P)
  /// lists actions (worktree navigation moved to the switcher).
  private var queryPlaceholder: String {
    switch store.mode {
    case .worktreeSwitcher:
      return "Go to worktree…"
    case .commands:
      return "Search for actions…"
    }
  }

  private func moveSelection(_ direction: MoveCommandDirection, rows: [CommandPaletteItem]) {
    switch direction {
    case .up:
      store.send(.moveSelection(.upSelection, itemsCount: rows.count))
    case .down:
      store.send(.moveSelection(.downSelection, itemsCount: rows.count))
    default:
      break
    }
  }

  private func submitSelected(rows: [CommandPaletteItem]) {
    let trimmed = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rows.isEmpty else { return }
    guard let selectedIndex = store.selectedIndex else {
      if trimmed.isEmpty {
        return
      }
      store.send(.activateItem(rows[0]))
      return
    }
    if rows.indices.contains(selectedIndex) {
      store.send(.activateItem(rows[selectedIndex]))
      return
    }
    store.send(.activateItem(rows[rows.count - 1]))
  }

  private func activate(_ id: CommandPaletteItem.ID, rows: [CommandPaletteItem]) {
    guard let item = rows.first(where: { $0.id == id }) else { return }
    store.send(.activateItem(item))
  }

  private func refreshFilteredItems(items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    let now = Date.now
    let updatedItems = CommandPaletteFeature.filterItems(
      items: items,
      query: store.query,
      mode: store.mode,
      recencyByID: store.recencyByItemID,
      now: now
    )
    filteredItems = updatedItems
    return updatedItems
  }
}

private struct CommandPaletteCard: View {
  static let width: CGFloat = 500

  @Binding var query: String
  @Binding var selectedIndex: Int?
  let items: [CommandPaletteItem]
  let placeholder: String
  @Binding var hoveredID: CommandPaletteItem.ID?
  let isQueryFocused: FocusState<Bool>
  let onEvent: (CommandPaletteKeyboardEvent) -> Void
  let activate: (CommandPaletteItem.ID) -> Void

  var body: some View {
    // No background / shadow / clip here: the host panel supplies a native
    // `NSGlassEffectView` glass, rounded corners, and window shadow.
    VStack(alignment: .leading, spacing: 0) {
      CommandPaletteQuery(query: $query, placeholder: placeholder, isTextFieldFocused: isQueryFocused) { event in
        onEvent(event)
      }

      Divider()

      CommandPaletteList(
        rows: items,
        selectedIndex: $selectedIndex,
        hoveredID: $hoveredID
      ) { id in
        activate(id)
      }
    }
    .frame(width: Self.width)
  }
}

private enum CommandPaletteKeyboardEvent: Equatable {
  case exit
  case submit
  case move(MoveCommandDirection)
}

private struct CommandPaletteQuery: View {
  static let fieldHeight: CGFloat = 48

  @Binding var query: String
  let placeholder: String
  var onEvent: ((CommandPaletteKeyboardEvent) -> Void)?
  @FocusState private var isTextFieldFocused: Bool

  init(
    query: Binding<String>,
    placeholder: String,
    isTextFieldFocused: FocusState<Bool>,
    onEvent: ((CommandPaletteKeyboardEvent) -> Void)? = nil
  ) {
    _query = query
    self.placeholder = placeholder
    self.onEvent = onEvent
    _isTextFieldFocused = isTextFieldFocused
  }

  // No hidden `.keyboardShortcut` buttons: they would stay registered app-wide
  // for as long as any window retains this view, swallowing plain ↑ / ↓ / ⌃P / ⌃N
  // everywhere. The panel's key monitor drives navigation while the palette is open.
  var body: some View {
    TextField(placeholder, text: $query)
      .padding()
      .font(.title3.weight(.light))
      .frame(height: Self.fieldHeight)
      .textFieldStyle(.plain)
      .focused($isTextFieldFocused)
      .onExitCommand { onEvent?(.exit) }
      .onMoveCommand { onEvent?(.move($0)) }
      .onSubmit { onEvent?(.submit) }
  }
}

private struct CommandPaletteList: View {
  static let listHeight: CGFloat = 205

  let rows: [CommandPaletteItem]
  @Binding var selectedIndex: Int?
  @Binding var hoveredID: CommandPaletteItem.ID?
  let activate: (CommandPaletteItem.ID) -> Void

  var body: some View {
    // Fixed height (blank when there are no matches) so the panel stays a
    // constant size; the host window is not resized while it is displayed.
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(rows.enumerated()), id: \.1.id) { index, row in
            CommandPaletteRowView(
              row: row,
              shortcutIndex: index < 5 ? index : nil,
              isSelected: isRowSelected(index: index),
              hoveredID: $hoveredID
            ) {
              activate(row.id)
            }
            .id(row.id)
          }
        }
        .padding(.horizontal, 10)
      }
      .frame(height: Self.listHeight)
      .contentMargins(.vertical, 10, for: .scrollContent)
      .scrollIndicators(.visible)
      .onChange(of: selectedIndex) { _, newValue in
        guard let selectedIndex = newValue, rows.indices.contains(selectedIndex) else { return }
        proxy.scrollTo(rows[selectedIndex].id)
      }
    }
  }

  private func isRowSelected(index: Int) -> Bool {
    guard let selectedIndex else { return false }
    if selectedIndex < rows.count {
      return selectedIndex == index
    }
    return index == rows.count - 1
  }
}

private struct CommandPaletteRowView: View {
  let row: CommandPaletteItem
  let shortcutIndex: Int?
  let isSelected: Bool
  @Binding var hoveredID: CommandPaletteItem.ID?
  let activate: () -> Void

  private var badge: String? {
    switch row.kind {
    case .checkForUpdates, .openRepository, .addRemoteRepository, .openSettings, .newWorktree,
      .viewArchivedWorktrees,
      .refreshWorktrees,
      .ghosttyCommand,
      .openPullRequest, .markPullRequestReady, .mergePullRequest, .closePullRequest, .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails, .worktreeSelect:
      return nil
    case .removeWorktree:
      return "Remove"
    case .archiveWorktree:
      return "Archive"
    case .renameBranch:
      return "Rename"
    case .runScript:
      return "Script"
    case .stopScript:
      return "Script"
    #if DEBUG
      case .debugTestToast:
        return "Debug"
    #endif
    }
  }

  private var leadingIcon: String? {
    switch row.kind {
    case .checkForUpdates:
      return "arrow.down.circle"
    case .openRepository:
      return "folder"
    case .addRemoteRepository:
      return "wifi"
    case .openSettings:
      return "gearshape"
    case .newWorktree:
      return "plus"
    case .viewArchivedWorktrees:
      return "archivebox"
    case .refreshWorktrees:
      return "arrow.clockwise"
    case .ghosttyCommand:
      return "terminal"
    case .openPullRequest:
      return "arrow.up.right.square"
    case .markPullRequestReady:
      return "checkmark.seal"
    case .mergePullRequest:
      return "arrow.merge"
    case .closePullRequest:
      return "xmark.circle"
    case .copyFailingJobURL:
      return "link"
    case .copyCiFailureLogs:
      return "doc.on.doc"
    case .rerunFailedJobs:
      return "arrow.counterclockwise"
    case .openFailingCheckDetails:
      return "exclamationmark.triangle"
    case .worktreeSelect:
      return nil
    case .removeWorktree:
      return "trash"
    case .archiveWorktree:
      return "archivebox"
    case .renameBranch:
      return "pencil"
    case .runScript(let definition):
      return definition.resolvedSystemImage
    case .stopScript:
      return "stop.fill"
    #if DEBUG
      case .debugTestToast:
        return "ladybug"
    #endif
    }
  }

  private var emphasis: Bool {
    switch row.kind {
    case .checkForUpdates, .openRepository, .addRemoteRepository, .openSettings, .newWorktree,
      .viewArchivedWorktrees,
      .refreshWorktrees,
      .ghosttyCommand,
      .openPullRequest, .markPullRequestReady, .mergePullRequest, .closePullRequest, .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails:
      return true
    case .worktreeSelect, .removeWorktree, .archiveWorktree:
      return false
    case .renameBranch:
      return true
    case .runScript, .stopScript:
      return true
    #if DEBUG
      case .debugTestToast:
        return true
    #endif
    }
  }

  /// Worktree-switcher title tint (else default), matching the sidebar.
  private var titleForegroundStyle: AnyShapeStyle {
    guard let tint = row.worktreeStyle?.titleTint else { return AnyShapeStyle(.primary) }
    return AnyShapeStyle(tint.color)
  }

  /// Worktree-switcher repo-subtitle tint (else secondary), matching the sidebar.
  private var subtitleForegroundStyle: AnyShapeStyle {
    guard let tint = row.worktreeStyle?.repoTint else { return AnyShapeStyle(.secondary) }
    return AnyShapeStyle(tint.color)
  }

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 8) {
        if let worktreeIcon = row.worktreeStyle?.icon {
          CommandPaletteWorktreeIcon(icon: worktreeIcon)
        } else if let leadingIcon {
          Image(systemName: leadingIcon)
            .foregroundStyle(emphasis ? .primary : .secondary)
            .font(.subheadline.weight(.medium))
            .frame(width: 16, height: 16, alignment: .center)
            .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: 2) {
          // Worktree rows tint the title / subtitle text and badge the remote
          // host, mirroring the sidebar. The host icon rides with the repo
          // subtitle for git rows and with the title for folders (no subtitle).
          HStack(spacing: 3) {
            Text(titleText)
              .fontWeight(emphasis ? .medium : .regular)
              .foregroundStyle(titleForegroundStyle)
            if row.subtitle == nil, let hostInfo = row.worktreeStyle?.hostInfo {
              CommandPaletteRemoteHostBadge(hostInfo: hostInfo)
            }
          }

          if let subtitle = row.subtitle {
            HStack(spacing: 3) {
              Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleForegroundStyle)
              if let hostInfo = row.worktreeStyle?.hostInfo {
                CommandPaletteRemoteHostBadge(hostInfo: hostInfo)
              }
            }
          }
        }

        Spacer()

        if let badge, !badge.isEmpty {
          Text(badge)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              Capsule().fill(Color(nsColor: .quaternaryLabelColor))
            )
            .foregroundStyle(.secondary)
        }

        if let shortcutIndex {
          ShortcutSymbolsView(symbols: commandPaletteShortcutSymbols(for: shortcutIndex))
            .foregroundStyle(.secondary)
        }
      }
      .padding(8)
      .contentShape(Rectangle())
      .transformEnvironment(\.colorScheme) { scheme in
        guard isSelected, scheme != .dark else { return }
        scheme = .dark
      }
      .background(rowBackground)
      .clipShape(.rect(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help(helpText)
    .onHover { hovering in
      hoveredID = hovering ? row.id : nil
    }
  }

  private var rowBackground: some View {
    Group {
      if isSelected {
        Color(nsColor: .selectedContentBackgroundColor)
      } else if hoveredID == row.id {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      } else {
        Color.clear
      }
    }
  }

  private var helpText: String {
    let base: String
    switch row.kind {
    case .worktreeSelect:
      base = "Switch to \(row.title)"
    case .checkForUpdates:
      base = "Check for Updates"
    case .openRepository:
      base = "Open Repository or Folder"
    case .addRemoteRepository:
      base = "Add Remote Repository"
    case .openSettings:
      base = "Open Settings"
    case .newWorktree:
      base = "New Worktree"
    case .viewArchivedWorktrees:
      base = "View Archived Worktrees"
    case .refreshWorktrees:
      base = "Refresh Worktrees"
    case .ghosttyCommand:
      base = row.title
    case .removeWorktree:
      base = "Remove \(row.title)"
    case .archiveWorktree:
      base = "Archive \(row.title)"
    case .renameBranch:
      base = "Rename the local branch for this worktree"
    case .openPullRequest:
      base = "Open pull request on GitHub"
    case .markPullRequestReady:
      base = "Mark pull request ready for review"
    case .mergePullRequest:
      base = "Merge pull request"
    case .closePullRequest:
      base = "Close pull request"
    case .copyFailingJobURL:
      base = "Copy failing job URL"
    case .copyCiFailureLogs:
      base = "Copy CI failure logs"
    case .rerunFailedJobs:
      base = "Re-run failed jobs"
    case .openFailingCheckDetails:
      base = "Open failing check details"
    case .runScript(let definition):
      base = "Run \(definition.name)"
    case .stopScript(_, let name):
      base = "Stop \(name)"
    #if DEBUG
      case .debugTestToast:
        base = row.title
    #endif
    }
    if let explicitShortcutLabel {
      return "\(base) (\(explicitShortcutLabel))"
    }
    if let shortcutIndex {
      return "\(base) (\(commandPaletteShortcutLabel(for: shortcutIndex)))"
    }
    return base
  }

  private var titleText: String {
    guard let shortcutLabel = row.appShortcutLabel else {
      return row.title
    }
    return "\(row.title) (\(shortcutLabel))"
  }

  private var explicitShortcutLabel: String? {
    row.appShortcutLabel
  }
}

/// Leading glyph for a worktree-switcher row, sized to the action-palette icon
/// slot and colored to mirror the sidebar (`IconContent`).
private struct CommandPaletteWorktreeIcon: View {
  let icon: CommandPaletteItem.WorktreeRowIcon

  var body: some View {
    Group {
      switch icon {
      case .pullRequest(let prIcon, _):
        Image(prIcon.assetName)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 14, height: 14)
          .foregroundStyle(prIcon.color)
          .opacity(0.6)
          .accessibilityHidden(true)
      case .folder:
        Image(systemName: "folder")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
          .opacity(0.6)
          .accessibilityHidden(true)
      case .missing:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.orange)
          .opacity(0.6)
          .accessibilityHidden(true)
      }
    }
    .frame(width: 16, height: 16, alignment: .center)
    .overlay(alignment: .bottomTrailing) {
      if case .pullRequest(_, let checkBadge?) = icon {
        CommandPaletteCheckBadge(state: checkBadge)
      }
    }
  }
}

/// CI check badge overlaid on a worktree-switcher pull-request icon, mirroring
/// the sidebar's palette-rendered badge (glyph in the window color, disc in the
/// status color).
private struct CommandPaletteCheckBadge: View {
  let state: SidebarCheckBadgeState

  var body: some View {
    Image(systemName: state.symbolName)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .symbolVariant(.circle.fill)
      .symbolRenderingMode(.palette)
      .fontWeight(.black)
      .frame(width: 10, height: 10)
      .foregroundStyle(.windowBackground, state.color)
      .background(in: Circle())
      .accessibilityLabel(state.statusDescription)
      .offset(x: 2, y: 2)
  }
}

private struct CommandPaletteRemoteHostBadge: View {
  let hostInfo: String

  var body: some View {
    Image(systemName: "wifi")
      .imageScale(.small)
      .foregroundStyle(.secondary)
      .help(hostInfo)
      .accessibilityLabel("Remote host \(hostInfo)")
  }
}

private struct ShortcutSymbolsView: View {
  let symbols: [String]

  var body: some View {
    HStack(spacing: 1) {
      ForEach(symbols, id: \.self) { symbol in
        Text(symbol)
          .frame(minWidth: 13)
      }
    }
  }
}

private func commandPaletteShortcutSymbols(for index: Int) -> [String] {
  ["⌘", "\(index + 1)"]
}

private func commandPaletteShortcutLabel(for index: Int) -> String {
  "Cmd+\(index + 1)"
}
