import AppKit
import ComposableArchitecture
import QuickLook
import SupacodeSettingsShared
import SwiftUI

/// Inspector pane rendering the selected worktree's file tree. The `List` is a
/// dumb iterator over the reducer-cached `rows`; all structure lives in
/// `FileExplorerFeature`.
struct WorktreeFilesInspectorView: View {
  let store: StoreOf<FileExplorerFeature>
  /// Installed editors that can open a single file, for the Open With submenu.
  let fileOpenActions: [OpenWorktreeAction]
  /// The toolbar's resolved editor, naming the default Open action.
  let resolvedOpenAction: OpenWorktreeAction?
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void

  var body: some View {
    VStack(spacing: 0) {
      FileExplorerPaneHeader(
        canRefresh: store.context?.unavailabilityReason == nil && store.context != nil,
        onRefresh: { store.send(.refreshButtonTapped) }
      )
      Divider()
      FileExplorerPaneContent(
        store: store,
        fileOpenActions: fileOpenActions,
        resolvedOpenAction: resolvedOpenAction,
        onOpenFile: onOpenFile
      )
    }
  }
}

private struct FileExplorerPaneHeader: View {
  let canRefresh: Bool
  let onRefresh: () -> Void

  var body: some View {
    HStack {
      Text("Files")
        .font(.headline)
      Spacer()
      Button(action: onRefresh) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(!canRefresh)
      .help("Reload the file tree.")
      .accessibilityLabel("Reload the file tree")
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }
}

private struct FileExplorerPaneContent: View {
  let store: StoreOf<FileExplorerFeature>
  let fileOpenActions: [OpenWorktreeAction]
  let resolvedOpenAction: OpenWorktreeAction?
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void

  var body: some View {
    if let context = store.context {
      switch context.unavailabilityReason {
      case .remote:
        FileExplorerUnavailableView(
          title: "Files Unavailable",
          description: "The file tree isn't available for remote worktrees yet."
        )
      case .missing:
        FileExplorerUnavailableView(
          title: "Folder Missing",
          description: "This worktree's folder is missing on disk."
        )
      case nil:
        FileExplorerTreeContent(
          store: store,
          fileOpenActions: fileOpenActions,
          resolvedOpenAction: resolvedOpenAction,
          onOpenFile: onOpenFile
        )
      }
    } else {
      FileExplorerUnavailableView(
        title: "No Selection",
        description: "Select a worktree to browse its files."
      )
    }
  }
}

private struct FileExplorerTreeContent: View {
  let store: StoreOf<FileExplorerFeature>
  let fileOpenActions: [OpenWorktreeAction]
  let resolvedOpenAction: OpenWorktreeAction?
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void

  var body: some View {
    if let failure = store.rootFailure {
      FileExplorerRootFailureView(
        failure: failure,
        onRetry: { store.send(.refreshButtonTapped) }
      )
    } else if store.rows.isEmpty {
      if store.isLoadingRoot {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        FileExplorerUnavailableView(
          title: "Empty Folder",
          description: "This worktree has no files."
        )
      }
    } else {
      FileExplorerListView(
        store: store,
        fileOpenActions: fileOpenActions,
        resolvedOpenAction: resolvedOpenAction,
        onOpenFile: onOpenFile
      )
    }
  }
}

private struct FileExplorerListView: View {
  let store: StoreOf<FileExplorerFeature>
  let fileOpenActions: [OpenWorktreeAction]
  let resolvedOpenAction: OpenWorktreeAction?
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void
  @State private var quickLookURL: URL?

  var body: some View {
    // Manual binding: `selectedRowID` is derived from the active tree, so it
    // can't back a writable key-path binding.
    List(
      selection: Binding(
        get: { store.selectedRowID },
        set: { store.send(.rowSelected($0)) }
      )
    ) {
      ForEach(store.rows) { row in
        FileExplorerRowView(
          row: row,
          fileURL: fileURL(for: row.id.entryPath),
          onToggleDirectory: { store.send(.directoryToggled($0)) },
          onShowMore: { store.send(.showMoreTapped(directory: $0)) }
        )
        .listRowInsets(.leading, CGFloat(row.depth) * FileExplorerRowLayout.indentStep)
        .listRowInsets(.trailing, 4)
        .listRowInsets(.vertical, 2)
      }
    }
    .contextMenu(forSelectionType: FileExplorerRowID.self) { ids in
      if let path = ids.first?.entryPath, let url = fileURL(for: path) {
        FileExplorerContextMenu(
          url: url,
          relativePath: path,
          fileOpenActions: fileOpenActions,
          resolvedOpenAction: resolvedOpenAction,
          onOpenFile: onOpenFile,
          onQuickLook: { quickLookURL = $0 }
        )
      }
    } primaryAction: { ids in
      activate(ids.first)
    }
    .onKeyPress(.return) {
      activate(store.selectedRowID) ? .handled : .ignored
    }
    .onKeyPress(.space) {
      quickLookSelectedRow() ? .handled : .ignored
    }
    .onMoveCommand { direction in
      switch direction {
      case .left: store.send(.collapseSelectedDirectory)
      case .right: store.send(.expandSelectedDirectory)
      default: break
      }
    }
    .quickLookPreview($quickLookURL)
    .scrollContentBackground(.hidden)
  }

  private func fileURL(for path: String?) -> URL? {
    guard let path, let root = store.context?.root else { return nil }
    return root.appending(path: path)
  }

  /// Double-click / Return: directories toggle, files open in the editor.
  @discardableResult
  private func activate(_ rowID: FileExplorerRowID?) -> Bool {
    guard
      let path = rowID?.entryPath,
      let entry = store.state.entry(at: path),
      let url = fileURL(for: path)
    else { return false }
    if entry.isDirectory {
      store.send(.directoryToggled(path))
    } else {
      onOpenFile(url, nil)
    }
    return true
  }

  private func quickLookSelectedRow() -> Bool {
    guard let url = fileURL(for: store.selectedRowID?.entryPath) else { return false }
    quickLookURL = url
    return true
  }
}

private struct FileExplorerContextMenu: View {
  let url: URL
  let relativePath: String
  let fileOpenActions: [OpenWorktreeAction]
  let resolvedOpenAction: OpenWorktreeAction?
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void
  let onQuickLook: (URL) -> Void

  var body: some View {
    Button(openTitle, systemImage: "arrow.up.right.square") {
      onOpenFile(url, nil)
    }
    if !fileOpenActions.isEmpty {
      Menu("Open With") {
        ForEach(fileOpenActions) { action in
          Button(action.title) {
            onOpenFile(url, action)
          }
        }
      }
    }
    Button("Quick Look", systemImage: "eye") {
      onQuickLook(url)
    }
    Divider()
    Button("Reveal in Finder", systemImage: "folder") {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    Divider()
    Button("Copy as Pathname", systemImage: "doc.on.doc") {
      copyToPasteboard(url.path(percentEncoded: false))
    }
    Button("Copy Relative Path", systemImage: "doc.on.doc") {
      copyToPasteboard(relativePath)
    }
  }

  private var openTitle: String {
    guard let resolvedOpenAction, resolvedOpenAction.canOpenFiles else { return "Open" }
    return "Open in \(resolvedOpenAction.title)"
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

/// Layout constants mirroring `SidebarNestLayout` so the tree reads like the
/// sidebar.
enum FileExplorerRowLayout {
  static let indentStep: CGFloat = 14
  static let iconSlotWidth: CGFloat = 16
  static let chevronWidth: CGFloat = 12
}

struct FileExplorerRowView: View {
  let row: FileExplorerRow
  let fileURL: URL?
  let onToggleDirectory: (String) -> Void
  let onShowMore: (String) -> Void

  var body: some View {
    switch row.kind {
    case .entry(let entry):
      FileExplorerEntryRowView(row: row, entry: entry, onToggleDirectory: onToggleDirectory)
        .tag(row.id)
        .draggableFileURL(fileURL)
    case .showMore(let remaining, let isLoading):
      FileExplorerShowMoreRowView(remaining: remaining, isLoading: isLoading) {
        onShowMore(row.path)
      }
      .selectionDisabled()
    }
  }
}

extension View {
  /// Rows drag plain file URLs; the terminal's existing drop handler owns the
  /// shell escaping, keeping a single escaping site.
  @ViewBuilder
  fileprivate func draggableFileURL(_ url: URL?) -> some View {
    if let url {
      onDrag { NSItemProvider(object: url as NSURL) }
    } else {
      self
    }
  }
}

private struct FileExplorerEntryRowView: View {
  let row: FileExplorerRow
  let entry: FileExplorerRow.Entry
  let onToggleDirectory: (String) -> Void
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    HStack(spacing: 6) {
      FileExplorerChevron(
        isDirectory: entry.isDirectory,
        isExpanded: entry.isExpanded,
        onToggle: {
          guard let path = row.id.entryPath else { return }
          onToggleDirectory(path)
        }
      )
      Image(systemName: entry.isDirectory ? "folder" : "doc")
        .resizable()
        .aspectRatio(contentMode: .fit)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .opacity(isEmphasized ? 1 : 0.6)
        .frame(width: FileExplorerRowLayout.iconSlotWidth, height: 16)
      Text(entry.name)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      if entry.isLoading {
        ProgressView()
          .controlSize(.mini)
      } else if let failure = entry.failure {
        Image(systemName: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(Self.failureHelp(failure))
      }
    }
    .contentShape(.rect)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var isEmphasized: Bool { backgroundProminence == .increased }

  private static func failureHelp(_ failure: FileExplorerListingError) -> String {
    switch failure {
    case .notFound: "This folder no longer exists. Expand it again to retry."
    case .permissionDenied: "Supacode doesn't have permission to read this folder. Expand it again to retry."
    case .unreadable: "Can't read this folder. Expand it again to retry."
    }
  }

  private var accessibilityLabel: String {
    var parts = [entry.isDirectory ? "Folder" : "File", entry.name]
    if entry.isSymbolicLink { parts.append("symbolic link") }
    if entry.failure != nil { parts.append("unreadable") }
    return parts.joined(separator: ", ")
  }
}

private struct FileExplorerChevron: View {
  let isDirectory: Bool
  let isExpanded: Bool
  let onToggle: () -> Void

  var body: some View {
    Button(action: onToggle) {
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
    .buttonStyle(.plain)
    .frame(width: FileExplorerRowLayout.chevronWidth)
    .opacity(isDirectory ? 1 : 0)
    .disabled(!isDirectory)
    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
  }
}

private struct FileExplorerShowMoreRowView: View {
  let remaining: Int
  let isLoading: Bool
  let onShowMore: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Color.clear
        .frame(width: FileExplorerRowLayout.chevronWidth)
      Color.clear
        .frame(width: FileExplorerRowLayout.iconSlotWidth)
      Button("Show \(remaining) More") {
        onShowMore()
      }
      .buttonStyle(.plain)
      .font(.body)
      .foregroundStyle(.secondary)
      .disabled(isLoading)
      .help("Load the next chunk of this folder's entries.")
      Spacer(minLength: 0)
    }
  }
}

private struct FileExplorerUnavailableView: View {
  let title: String
  let description: String

  var body: some View {
    ContentUnavailableView(
      title,
      systemImage: "folder.badge.questionmark",
      description: Text(description)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct FileExplorerRootFailureView: View {
  let failure: FileExplorerListingError
  let onRetry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Can't Read Folder", systemImage: "folder.badge.questionmark")
    } description: {
      Text(description)
    } actions: {
      Button("Try Again", action: onRetry)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var description: String {
    switch failure {
    case .notFound: "This folder no longer exists on disk."
    case .permissionDenied: "Supacode doesn't have permission to read this folder."
    case .unreadable: "This folder can't be read."
    }
  }
}
