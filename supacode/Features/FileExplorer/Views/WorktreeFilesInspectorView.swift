import ComposableArchitecture
import QuickLook
import SupacodeSettingsShared
import SwiftUI

/// Inspector pane rendering the selected worktree's file tree via the
/// outline bridge; all structure lives in `FileExplorerFeature`.
struct WorktreeFilesInspectorView: View {
  let store: StoreOf<FileExplorerFeature>
  /// Installed editors that can open a single file, for the Open With submenu.
  let fileOpenActions: [OpenWorktreeAction]
  /// The toolbar's resolved editor, naming the default Open action.
  let resolvedOpenAction: OpenWorktreeAction?
  let onOpenFile: (URL, OpenWorktreeAction?) -> Void

  var body: some View {
    VStack(spacing: 0) {
      FileExplorerPaneHeader(rootPath: store.context?.root?.path(percentEncoded: false))
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
  let rootPath: String?

  var body: some View {
    HStack {
      Text("Files")
        .font(.headline)
        .help(tooltip)
      Spacer(minLength: 0)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  /// The pane title stays short; the root's full path lives in the tooltip.
  private var tooltip: String {
    guard let rootPath else { return "Files" }
    return (rootPath as NSString).abbreviatingWithTildeInPath
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
  @State private var quickLookURL: URL?
  @Environment(OpenActionIconStore.self) private var iconStore: OpenActionIconStore?

  var body: some View {
    Group {
      if let tree = store.activeTree, let rootListing = store.rootListing {
        if rootListing.entries.isEmpty, !rootListing.isTruncated {
          FileExplorerUnavailableView(
            title: "Empty Folder",
            description: "This worktree has no files."
          )
        } else {
          FileExplorerOutlineView(
            tree: tree,
            fileOpenActions: fileOpenActions,
            resolvedOpenAction: resolvedOpenAction,
            menuIcon: menuIcon(for:),
            actions: FileExplorerOutlineActions(
              toggleDirectory: { store.send(.directoryToggled($0)) },
              select: { store.send(.rowSelected($0)) },
              openFile: onOpenFile,
              showMore: { store.send(.showMoreTapped(directory: $0)) },
              quickLook: { quickLookURL = $0 }
            )
          )
          .quickLookPreview($quickLookURL)
          .onDisappear { quickLookURL = nil }
        }
      } else if let failure = store.rootFailure {
        FileExplorerRootFailureView(
          failure: failure,
          onRetry: { store.send(.refreshRequested) }
        )
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // A held-over URL would re-present Quick Look on reattach, or preview a
    // file from a previously selected worktree.
    .onChange(of: store.activeWorktreeID) { _, _ in
      quickLookURL = nil
    }
    // Finder behavior: while the preview is open, it follows the selection.
    .onChange(of: store.selectedPath) { _, newPath in
      guard quickLookURL != nil else { return }
      guard let newPath, let root = store.context?.root else {
        quickLookURL = nil
        return
      }
      quickLookURL = root.appending(path: newPath)
    }
  }

  /// Mirrors `OpenWorktreeActionIcon`: an SF Symbol when the action defines
  /// one, otherwise the baked app icon; read, never resolved.
  private func menuIcon(for action: OpenWorktreeAction) -> NSImage? {
    if let symbolName = action.menuSymbolName {
      return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }
    return iconStore?.icon(for: action)
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
        .help("Reload this folder.")
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
