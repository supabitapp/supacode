import AppKit
import SupacodeSettingsShared
import SwiftUI
import UniformTypeIdentifiers

/// Callbacks the outline bridge fires back into SwiftUI / the reducer.
struct FileExplorerOutlineActions {
  var toggleDirectory: (String) -> Void
  var select: (String?) -> Void
  var openFile: (URL, OpenWorktreeAction?) -> Void
  var showMore: (String) -> Void
  var quickLook: (URL) -> Void
  /// Stage or unstage the path, resolved from its current git state.
  var stageToggle: (String) -> Void
  var discard: (String) -> Void
}

/// NSOutlineView-backed tree. AppKit owns selection, disclosure, keyboard,
/// type-ahead, drag, and context menus; the reducer stays the source of truth
/// for expansion, selection, and listings, applied here on every update.
struct FileExplorerOutlineView: NSViewRepresentable {
  let tree: FileExplorerFeature.TreeState
  let fileOpenActions: [OpenWorktreeAction]
  let resolvedOpenAction: OpenWorktreeAction?
  /// Menu icon per open action: a baked app icon or an SF Symbol.
  let menuIcon: (OpenWorktreeAction) -> NSImage?
  let actions: FileExplorerOutlineActions
  /// Height of the SwiftUI breadcrumb bar the outline draws under, so its rows
  /// still clear the bar. SwiftUI zeroes the ignored safe area for this opaque
  /// view, so we feed the inset in explicitly.
  let bottomBarInset: CGFloat

  /// Extra distance above the breadcrumb bar over which the blur fades out.
  private static let blurFadeHeight: CGFloat = 20

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let outlineView = FileExplorerNSOutlineView()
    outlineView.coordinator = context.coordinator
    outlineView.headerView = nil
    // Inset style: rounded selection and side margins, matching the sidebar's
    // modern look without source-list vibrancy fighting the forced appearance.
    outlineView.style = .inset
    outlineView.rowSizeStyle = .default
    outlineView.usesAutomaticRowHeights = true
    outlineView.intercellSpacing = NSSize(width: 0, height: 2)
    outlineView.indentationPerLevel = 14
    outlineView.autoresizesOutlineColumn = false
    // Keep the single column pinned to the visible width so long names
    // truncate in place instead of running under the pane edge.
    outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    outlineView.autosaveExpandedItems = false
    outlineView.allowsMultipleSelection = false
    outlineView.allowsEmptySelection = true
    outlineView.backgroundColor = .clear
    outlineView.focusRingType = .none
    // Both masks: the terminal drop target is in-process (a local drag).
    outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
    outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
    outlineView.target = context.coordinator
    outlineView.doubleAction = #selector(Coordinator.outlineViewDoubleClicked(_:))

    let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
    column.resizingMask = .autoresizingMask
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column

    let menu = NSMenu()
    menu.delegate = context.coordinator
    outlineView.menu = menu

    outlineView.dataSource = context.coordinator
    outlineView.delegate = context.coordinator

    let scrollView = NSScrollView()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.horizontalScrollElasticity = .none
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    context.coordinator.outlineView = outlineView
    context.coordinator.scrollView = scrollView

    // Progressive bottom fade: a within-window blur overlay masked by a vertical
    // gradient, approximating the toolbar's scroll-edge effect over the outline.
    let blur = ProgressiveBlurView()
    blur.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(scrollView)
    container.addSubview(blur)
    let blurHeight = blur.heightAnchor.constraint(equalToConstant: bottomBarInset + Self.blurFadeHeight)
    context.coordinator.blurHeightConstraint = blurHeight
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      blurHeight,
    ])
    return container
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeKeyMonitor()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.apply(
      tree: tree,
      fileOpenActions: fileOpenActions,
      resolvedOpenAction: resolvedOpenAction,
      menuIcon: menuIcon,
      actions: actions
    )
    // Inset the rows past the breadcrumb bar the outline now draws under. Added
    // to the safe area so it composes with the automatic titlebar inset up top.
    if let scrollView = context.coordinator.scrollView,
      scrollView.additionalSafeAreaInsets.bottom != bottomBarInset
    {
      scrollView.additionalSafeAreaInsets.bottom = bottomBarInset
    }
    context.coordinator.blurHeightConstraint?.constant = bottomBarInset + Self.blurFadeHeight
  }

  /// One outline item. Reference type because NSOutlineView tracks items by
  /// identity; the coordinator caches them per path so identity is stable
  /// across reloads.
  final class OutlineItem {
    enum Kind {
      case entry(FileExplorerEntry)
      case showMore(remaining: Int, isLoading: Bool)
    }

    let path: String
    var kind: Kind

    init(path: String, kind: Kind) {
      self.path = path
      self.kind = kind
    }

    var entry: FileExplorerEntry? {
      guard case .entry(let entry) = kind else { return nil }
      return entry
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    static let columnIdentifier = NSUserInterfaceItemIdentifier("fileExplorerColumn")
    private static let logger = SupaLogger("FileExplorer")

    weak var outlineView: NSOutlineView?
    weak var scrollView: NSScrollView?
    var blurHeightConstraint: NSLayoutConstraint?
    private var keyMonitor: Any?
    private(set) var tree: FileExplorerFeature.TreeState?
    private var fileOpenActions: [OpenWorktreeAction] = []
    private var resolvedOpenAction: OpenWorktreeAction?
    private var menuIcon: ((OpenWorktreeAction) -> NSImage?)?
    private var actions: FileExplorerOutlineActions?
    /// Entry items cached by path; show-more items by listed directory.
    private var entryItems: [String: OutlineItem] = [:]
    private var showMoreItems: [String: OutlineItem] = [:]
    /// Children arrays memoized per directory; NSOutlineView queries the data
    /// source per row, so rebuilding these on access would be quadratic.
    private var childrenCache: [String: [OutlineItem]] = [:]
    /// Suppresses delegate feedback while state is applied programmatically.
    private var isApplyingState = false

    func apply(
      tree: FileExplorerFeature.TreeState,
      fileOpenActions: [OpenWorktreeAction],
      resolvedOpenAction: OpenWorktreeAction?,
      menuIcon: @escaping (OpenWorktreeAction) -> NSImage?,
      actions: FileExplorerOutlineActions
    ) {
      self.fileOpenActions = fileOpenActions
      self.resolvedOpenAction = resolvedOpenAction
      self.menuIcon = menuIcon
      self.actions = actions
      guard let outlineView else { return }
      let previous = self.tree
      self.tree = tree
      let structureChanged =
        previous?.root != tree.root
        || previous?.directories != tree.directories
        || previous?.expanded != tree.expanded
        // Deletions add/remove tombstone rows, which only `refreshItems` builds,
        // so a status-only tick that changes them still needs a structural pass.
        || Self.deletedPaths(previous?.gitStatus) != Self.deletedPaths(tree.gitStatus)
      // A background re-list (the 5s sweep) reloads/expands/selects rows; those
      // must never yank first responder away from wherever the user is working,
      // e.g. a terminal surface.
      let priorResponder = outlineView.window?.firstResponder
      if structureChanged {
        isApplyingState = true
        refreshItems(for: tree)
        outlineView.reloadData()
        applyExpansion(tree, outlineView: outlineView)
        isApplyingState = false
      } else if previous?.gitStatus != tree.gitStatus {
        // Status-only tick (the steady state under an active agent): redraw just
        // the rows whose decoration changed, so scroll, selection, and any
        // inline rename survive instead of a full reloadData every 5s.
        reloadChangedGitRows(previous: previous?.gitStatus, next: tree.gitStatus, outlineView: outlineView)
      }
      applySelection(tree, outlineView: outlineView)
      restoreFirstResponderIfStolen(from: priorResponder, outlineView: outlineView)
    }

    /// Reclaims first responder for `prior` if applying state pulled it into the
    /// outline unprompted. A genuine click on a row routes through the outline's
    /// own event handling, not here, so this never fights real user focus.
    private func restoreFirstResponderIfStolen(from prior: NSResponder?, outlineView: NSOutlineView) {
      guard let window = outlineView.window else { return }
      let current = window.firstResponder
      guard current !== prior else { return }
      func belongsToOutline(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === outlineView || view.isDescendant(of: outlineView)
      }
      guard belongsToOutline(current), !belongsToOutline(prior) else { return }
      if !window.makeFirstResponder(prior) {
        Self.logger.debug("Couldn't hand first responder back after applying the file tree.")
      }
    }

    /// Rebuild item kinds in place so cached identities survive reloads.
    private func refreshItems(for tree: FileExplorerFeature.TreeState) {
      var alivePaths: Set<String> = []
      var aliveShowMore: Set<String> = []
      for (directory, node) in tree.directories {
        guard let listing = node.listing else { continue }
        for entry in listing.entries {
          let path = FileExplorerFeature.childPath(of: directory, name: entry.name)
          alivePaths.insert(path)
          if let item = entryItems[path] {
            item.kind = .entry(entry)
          } else {
            entryItems[path] = OutlineItem(path: path, kind: .entry(entry))
          }
        }
        if listing.isTruncated {
          aliveShowMore.insert(directory)
          let kind = OutlineItem.Kind.showMore(
            remaining: listing.totalCount - listing.entries.count,
            isLoading: node.isLoading
          )
          if let item = showMoreItems[directory] {
            item.kind = kind
          } else {
            showMoreItems[directory] = OutlineItem(path: directory, kind: kind)
          }
        }
      }
      // Deletions that are gone from disk have no filesystem entry, so surface a
      // tombstone row under each loaded parent. A deletion whose working copy is
      // still present (e.g. `git rm --cached`) is already listed, so it's skipped.
      var tombstonesByParent: [String: [OutlineItem]] = [:]
      for (path, status) in tree.gitStatus.statuses
      where (status.index == .deleted || status.worktree == .deleted) && !alivePaths.contains(path) {
        let parent = FileExplorerFeature.parentDirectory(of: path)
        guard tree.directories[parent]?.listing != nil else { continue }
        alivePaths.insert(path)
        let entry = FileExplorerEntry(
          name: (path as NSString).lastPathComponent, isDirectory: false, isSymbolicLink: false
        )
        let item = entryItems[path] ?? OutlineItem(path: path, kind: .entry(entry))
        item.kind = .entry(entry)
        entryItems[path] = item
        tombstonesByParent[parent, default: []].append(item)
      }

      entryItems = entryItems.filter { alivePaths.contains($0.key) }
      showMoreItems = showMoreItems.filter { aliveShowMore.contains($0.key) }
      childrenCache = tree.directories.reduce(into: [:]) { cache, element in
        guard let listing = element.value.listing else { return }
        var items = listing.entries.compactMap {
          entryItems[FileExplorerFeature.childPath(of: element.key, name: $0.name)]
        }
        if listing.isTruncated, let showMore = showMoreItems[element.key] {
          items.append(showMore)
        }
        cache[element.key] = items
      }
      // Splice tombstones in ahead of any trailing show-more row.
      for (parent, tombstones) in tombstonesByParent {
        var items = childrenCache[parent] ?? []
        let insertionIndex = showMoreItems[parent] != nil && !items.isEmpty ? items.count - 1 : items.count
        items.insert(
          contentsOf: tombstones.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
          at: insertionIndex
        )
        childrenCache[parent] = items
      }
    }

    private func applyExpansion(_ tree: FileExplorerFeature.TreeState, outlineView: NSOutlineView) {
      // Shallowest first, so a parent exists before its child expands.
      let ordered = tree.expanded.sorted { lhs, rhs in
        lhs.count(where: { $0 == "/" }) < rhs.count(where: { $0 == "/" })
      }
      for path in ordered {
        guard let item = entryItems[path] else { continue }
        outlineView.expandItem(item)
      }
      // Contract anything the reducer no longer marks expanded; `expandItem`
      // alone never contracts a row.
      for (path, item) in entryItems where !tree.expanded.contains(path) {
        guard outlineView.isItemExpanded(item) else { continue }
        outlineView.collapseItem(item)
      }
    }

    private func applySelection(_ tree: FileExplorerFeature.TreeState, outlineView: NSOutlineView) {
      let targetRow = tree.selectedPath.flatMap { path -> Int? in
        guard let item = entryItems[path] else { return nil }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? row : nil
      }
      let currentRow = outlineView.selectedRow >= 0 ? outlineView.selectedRow : nil
      guard targetRow != currentRow else { return }
      isApplyingState = true
      if let targetRow {
        outlineView.selectRowIndexes([targetRow], byExtendingSelection: false)
      } else {
        outlineView.deselectAll(nil)
      }
      isApplyingState = false
    }

    /// Paths whose file is gone from disk (a staged or worktree deletion), which
    /// drive tombstone rows.
    private static func deletedPaths(_ snapshot: GitStatusSnapshot?) -> Set<String> {
      guard let snapshot else { return [] }
      return Set(snapshot.statuses.filter { $0.value.index == .deleted || $0.value.worktree == .deleted }.keys)
    }

    /// Redraws only the rows whose git decoration could differ between two
    /// snapshots: files with a changed status and directories whose rollup
    /// letter flipped. An ignored-set change affects whole subtrees by prefix
    /// and is rare, so that case falls back to a full reload.
    private func reloadChangedGitRows(
      previous: GitStatusSnapshot?,
      next: GitStatusSnapshot,
      outlineView: NSOutlineView
    ) {
      let previous = previous ?? .empty
      guard previous.ignoredPrefixes == next.ignoredPrefixes else {
        outlineView.reloadData()
        return
      }
      var changedPaths: Set<String> = []
      // A directory row changes when its rollup appears, disappears, or flips
      // between added and modified, so compare the mapped state, not just keys.
      for key in Set(previous.changedAncestors.keys).union(next.changedAncestors.keys)
      where previous.changedAncestors[key] != next.changedAncestors[key] {
        changedPaths.insert(key)
      }
      for key in Set(previous.statuses.keys).union(next.statuses.keys)
      where previous.statuses[key] != next.statuses[key] {
        changedPaths.insert(key)
      }
      for path in changedPaths {
        guard let item = entryItems[path], outlineView.row(forItem: item) >= 0 else { continue }
        outlineView.reloadItem(item, reloadChildren: false)
      }
    }

    private func listing(for directory: String) -> FileExplorerListing? {
      tree?.directories[directory]?.listing
    }

    private func children(of directory: String) -> [OutlineItem] {
      childrenCache[directory] ?? []
    }

    private func url(for path: String) -> URL? {
      guard let tree else { return nil }
      guard path != FileExplorerFeature.TreeState.rootPath else { return tree.root }
      return tree.root.appending(path: path)
    }

    // MARK: Activation.

    /// Double-click and Return: directories toggle, files open in the system's
    /// default app (Finder behavior). Configured editors live in the menu.
    func activate(item: OutlineItem) {
      guard let entry = item.entry else { return }
      if entry.isDirectory {
        actions?.toggleDirectory(item.path)
      } else if let url = url(for: item.path) {
        openInDefaultApp(url)
      }
    }

    /// Opens the file with the system's default app, logging when nothing can.
    private func openInDefaultApp(_ url: URL) {
      guard !NSWorkspace.shared.open(url) else { return }
      Self.logger.warning("No system-default app opened \(url.lastPathComponent).")
    }

    @discardableResult
    func quickLookSelection() -> Bool {
      guard
        let outlineView,
        let item = outlineView.item(atRow: outlineView.selectedRow) as? OutlineItem,
        item.entry != nil,
        let url = url(for: item.path)
      else { return false }
      actions?.quickLook(url)
      return true
    }

    // MARK: Row keyboard shortcuts.

    /// Lets a selected row's shortcuts beat the worktree menu commands that
    /// share these chords, but only while the outline is focused with a row
    /// selected, so those commands pass through untouched elsewhere.
    func installKeyMonitor() {
      guard keyMonitor == nil else { return }
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, self.handleRowShortcut(event) else { return event }
        return nil
      }
    }

    func removeKeyMonitor() {
      guard let keyMonitor else { return }
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }

    private func handleRowShortcut(_ event: NSEvent) -> Bool {
      guard
        let outlineView,
        let window = outlineView.window, window.isKeyWindow,
        let responder = window.firstResponder as? NSView,
        responder === outlineView || responder.isDescendant(of: outlineView),
        outlineView.selectedRow >= 0,
        let item = outlineView.item(atRow: outlineView.selectedRow) as? OutlineItem,
        item.entry != nil
      else { return false }
      // Match letters by produced character so the chords track the keyboard
      // layout (and the menu's key equivalents); the Delete key is positional.
      let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
      switch (event.charactersIgnoringModifiers?.lowercased(), event.keyCode, mods) {
      case ("o", _, [.command]):  // Cmd+O: open in the system default app.
        if let url = url(for: item.path) { openInDefaultApp(url) }
        return true
      case ("r", _, [.command, .option]):  // Opt+Cmd+R: reveal in Finder.
        if let url = url(for: item.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        return true
      case ("c", _, [.command]):  // Cmd+C: copy the file, like the Finder.
        if let url = url(for: item.path) { copyFileToPasteboard(url) }
        return true
      case ("c", _, [.command, .option]):  // Opt+Cmd+C: copy the absolute pathname.
        if let url = url(for: item.path) { copyToPasteboard(url.path(percentEncoded: false)) }
        return true
      case (_, 51, [.command]):  // Cmd+Delete: move a removable file to the Trash.
        return discardSelected(item, matching: .trash)
      case (_, 51, [.command, .shift]):  // Shift+Cmd+Delete: discard a tracked change.
        return discardSelected(item, matching: .restore)
      default:
        return false
      }
    }

    /// Discards the row when its state matches the requested kind, beeping
    /// otherwise. Always swallows the event so a delete chord never falls
    /// through to Delete Worktree while the user is browsing files.
    private func discardSelected(_ item: OutlineItem, matching kind: GitDiscardKind) -> Bool {
      if tree?.gitStatus.statuses[item.path]?.discardKind == kind {
        actions?.discard(item.path)
      } else {
        NSSound.beep()
      }
      return true
    }

    @objc func outlineViewDoubleClicked(_ sender: Any?) {
      guard
        let outlineView,
        outlineView.clickedRow >= 0,
        let item = outlineView.item(atRow: outlineView.clickedRow) as? OutlineItem
      else { return }
      activate(item: item)
    }

    // MARK: Context menu actions.

    @objc private func contextMenuOpen(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String, let url = url(for: path) else { return }
      openInDefaultApp(url)
    }

    @objc private func contextMenuOpenWith(_ sender: NSMenuItem) {
      guard
        let payload = sender.representedObject as? OpenWithPayload,
        let url = url(for: payload.path)
      else { return }
      actions?.openFile(url, payload.action)
    }

    @objc private func contextMenuQuickLook(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String, let url = url(for: path) else { return }
      actions?.quickLook(url)
    }

    @objc private func contextMenuStage(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String else { return }
      actions?.stageToggle(path)
    }

    @objc private func contextMenuDiscard(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String else { return }
      actions?.discard(path)
    }

    @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String, let url = url(for: path) else { return }
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func contextMenuCopyFile(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String, let url = url(for: path) else { return }
      copyFileToPasteboard(url)
    }

    @objc private func contextMenuCopyPathname(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String, let url = url(for: path) else { return }
      copyToPasteboard(url.path(percentEncoded: false))
    }

    @objc private func contextMenuCopyRelativePath(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String else { return }
      copyToPasteboard(path)
    }

    private func copyToPasteboard(_ value: String) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    }

    /// Writes the file URL so Finder (and any file-aware app) can paste the file
    /// itself, matching Cmd+C in the Finder.
    private func copyFileToPasteboard(_ url: URL) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([url as NSURL])
    }

    private final class OpenWithPayload: NSObject {
      let path: String
      let action: OpenWorktreeAction

      init(path: String, action: OpenWorktreeAction) {
        self.path = path
        self.action = action
      }
    }
  }
}

extension FileExplorerOutlineView.Coordinator: NSOutlineViewDataSource {
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item = item as? FileExplorerOutlineView.OutlineItem else {
      return children(of: FileExplorerFeature.TreeState.rootPath).count
    }
    guard item.entry?.isDirectory == true else { return 0 }
    return children(of: item.path).count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    let directory = (item as? FileExplorerOutlineView.OutlineItem)?.path ?? FileExplorerFeature.TreeState.rootPath
    return children(of: directory)[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? FileExplorerOutlineView.OutlineItem)?.entry?.isDirectory == true
  }

  func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
    guard
      let item = item as? FileExplorerOutlineView.OutlineItem,
      item.entry != nil,
      let url = url(for: item.path)
    else { return nil }
    // Plain file URLs: the terminal's existing drop handler owns the shell
    // escaping, keeping a single escaping site.
    return url as NSURL
  }
}

extension FileExplorerOutlineView.Coordinator: NSOutlineViewDelegate {
  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let item = item as? FileExplorerOutlineView.OutlineItem else { return nil }
    switch item.kind {
    case .entry(let entry):
      let cell =
        outlineView.makeView(
          withIdentifier: FileExplorerEntryCellView.identifier, owner: nil
        ) as? FileExplorerEntryCellView ?? FileExplorerEntryCellView()
      let childNode = entry.isDirectory ? tree?.directories[item.path] : nil
      let isLoading = childNode?.isLoading ?? false
      let hasListing = childNode?.listing != nil
      // First-time expansion shimmers the row's own label; a refresh (with a
      // previous listing) keeps the spinner. Reduce Motion falls back to it too.
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      let isFirstTimeLoading = isLoading && !hasListing
      let decoration = tree?.gitStatus.decoration(
        for: item.path,
        isDirectory: entry.isDirectory,
        isExpanded: outlineView.isItemExpanded(item)
      )
      cell.configure(
        with: entry,
        isLoading: isLoading && (hasListing || reduceMotion),
        isShimmering: isFirstTimeLoading && !reduceMotion,
        failure: childNode?.failure,
        decoration: decoration
      )
      return cell
    case .showMore(let remaining, let isLoading):
      let cell =
        outlineView.makeView(
          withIdentifier: FileExplorerShowMoreCellView.identifier, owner: nil
        ) as? FileExplorerShowMoreCellView ?? FileExplorerShowMoreCellView()
      let directory = item.path
      cell.configure(remaining: remaining, isLoading: isLoading) { [weak self] in
        self?.actions?.showMore(directory)
      }
      return cell
    }
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    (item as? FileExplorerOutlineView.OutlineItem)?.entry != nil
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    guard !isApplyingState, let outlineView else { return }
    let path = (outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerOutlineView.OutlineItem)?.path
    guard path != tree?.selectedPath else { return }
    actions?.select(path)
  }

  func outlineViewItemDidExpand(_ notification: Notification) {
    guard !isApplyingState else { return }
    guard let item = notification.userInfo?["NSObject"] as? FileExplorerOutlineView.OutlineItem else { return }
    guard tree?.expanded.contains(item.path) == false else { return }
    actions?.toggleDirectory(item.path)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard !isApplyingState else { return }
    guard let item = notification.userInfo?["NSObject"] as? FileExplorerOutlineView.OutlineItem else { return }
    guard tree?.expanded.contains(item.path) == true else { return }
    actions?.toggleDirectory(item.path)
  }

}

extension FileExplorerOutlineView.Coordinator: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    guard
      let outlineView,
      outlineView.clickedRow >= 0,
      let item = outlineView.item(atRow: outlineView.clickedRow) as? FileExplorerOutlineView.OutlineItem,
      item.entry != nil
    else { return }
    let path = item.path

    addGitMenuItems(to: menu, path: path)

    // Open with the system default app, matching a double-click.
    menu.addItem(
      makeItem(
        "Open", action: #selector(contextMenuOpen(_:)), symbolName: "arrow.up.right.square", representing: path,
        keyEquivalent: "o", modifiers: .command
      )
    )

    // Configured editors live on the right-click menu only: the resolved (or
    // first) file-capable editor, then the full submenu below.
    let primary =
      (resolvedOpenAction?.canOpenFiles == true ? resolvedOpenAction : nil) ?? fileOpenActions.first
    if let primary {
      // No icon: only the system "Open" above carries the arrow glyph.
      let openWith = NSMenuItem(
        title: "Open with \(primary.labelTitle)",
        action: #selector(contextMenuOpenWith(_:)),
        keyEquivalent: ""
      )
      openWith.target = self
      openWith.representedObject = OpenWithPayload(path: path, action: primary)
      menu.addItem(openWith)
    }

    if !fileOpenActions.isEmpty {
      let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      for action in fileOpenActions {
        let item = NSMenuItem(
          title: action.labelTitle, action: #selector(contextMenuOpenWith(_:)), keyEquivalent: ""
        )
        item.target = self
        item.image = menuIcon?(action)
        item.representedObject = OpenWithPayload(path: path, action: action)
        submenu.addItem(item)
      }
      openWith.submenu = submenu
      menu.addItem(openWith)
    }

    menu.addItem(
      makeItem("Quick Look", action: #selector(contextMenuQuickLook(_:)), symbolName: "eye", representing: path)
    )
    menu.addItem(.separator())
    menu.addItem(
      makeItem(
        "Reveal in Finder", action: #selector(contextMenuRevealInFinder(_:)), symbolName: "folder",
        representing: path, keyEquivalent: "r", modifiers: [.command, .option]
      )
    )
    menu.addItem(.separator())
    menu.addItem(
      makeItem(
        "Copy", action: #selector(contextMenuCopyFile(_:)), symbolName: "document.on.document.fill",
        representing: path, keyEquivalent: "c", modifiers: .command
      )
    )
    menu.addItem(
      makeItem(
        "Copy as Pathname", action: #selector(contextMenuCopyPathname(_:)), symbolName: "doc.on.doc",
        representing: path, keyEquivalent: "c", modifiers: [.command, .option]
      )
    )
    menu.addItem(
      makeItem(
        "Copy Relative Path", action: #selector(contextMenuCopyRelativePath(_:)), symbolName: nil,
        representing: path
      )
    )
  }

  /// Git actions for the clicked entry, above the rest of the menu. Nothing for
  /// a clean, conflicted, or non-git row. Discard on an untracked file is a
  /// Trash move, worded to match; both destructive items confirm.
  private func addGitMenuItems(to menu: NSMenu, path: String) {
    guard let status = tree?.gitStatus.statuses[path], !status.isConflicted else { return }
    if status.hasUnstagedChange {
      menu.addItem(
        makeItem(
          "Stage Changes", action: #selector(contextMenuStage(_:)), symbolName: "plus.circle", representing: path
        )
      )
    } else if status.hasStagedChange {
      menu.addItem(
        makeItem(
          "Unstage Changes", action: #selector(contextMenuStage(_:)), symbolName: "minus.circle", representing: path
        )
      )
    }
    switch status.discardKind {
    case .trash:
      menu.addItem(
        makeItem(
          "Move to Trash…", action: #selector(contextMenuDiscard(_:)), symbolName: "trash", representing: path,
          keyEquivalent: "\u{8}", modifiers: .command
        )
      )
    case .restore:
      menu.addItem(
        makeItem(
          "Discard Changes…", action: #selector(contextMenuDiscard(_:)), symbolName: "arrow.uturn.backward",
          representing: path, keyEquivalent: "\u{8}", modifiers: [.command, .shift]
        )
      )
    case nil:
      break
    }
    menu.addItem(.separator())
  }

  private func makeItem(
    _ title: String,
    action: Selector,
    symbolName: String?,
    representing path: String,
    keyEquivalent: String = "",
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    item.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    item.representedObject = path
    return item
  }
}

/// Outline subclass adding Return-to-activate and Space-to-Quick-Look.
private final class FileExplorerNSOutlineView: NSOutlineView {
  weak var coordinator: FileExplorerOutlineView.Coordinator?

  // Tie the app-global key monitor to window membership so it can't outlive the
  // view (which `dismantleNSView` alone doesn't guarantee) and accumulate.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      coordinator?.removeKeyMonitor()
    } else {
      coordinator?.installKeyMonitor()
    }
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76:
      guard
        let coordinator,
        selectedRow >= 0,
        let item = item(atRow: selectedRow) as? FileExplorerOutlineView.OutlineItem
      else { break }
      coordinator.activate(item: item)
      return
    case 49:
      guard coordinator?.quickLookSelection() == true else { break }
      return
    default:
      break
    }
    super.keyDown(with: event)
  }
}

/// A within-window blur overlay masked by a vertical gradient, so the effect
/// fades from full blur at the bottom to clear going up: an approximation of
/// the system scroll-edge effect for the AppKit outline behind it.
private final class ProgressiveBlurView: NSVisualEffectView {
  private var maskedSize: NSSize = .zero

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    blendingMode = .withinWindow
    material = .headerView
    state = .active
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  // Decorative only: let clicks, drags, and scroll reach the outline rows behind
  // the fade instead of landing on the overlay.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    // Regenerate only on a real size change; redrawing the gradient every layout
    // pass would burn CPU while the outline scrolls. The gradient is opaque (full
    // blur) at the bottom edge and clears toward the top.
    guard bounds.size != maskedSize else { return }
    maskedSize = bounds.size
    maskImage = Self.gradientMask(size: bounds.size)
  }

  private static func gradientMask(size: NSSize) -> NSImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    return NSImage(size: size, flipped: false) { rect in
      guard let gradient = NSGradient(colors: [.black, .clear]) else { return false }
      // 90°: the first color (opaque) sits at the bottom, fading up to clear.
      gradient.draw(in: rect, angle: 90)
      return true
    }
  }
}

/// Finder's own document icons, resolved by content type and memoized per file
/// extension so the tree reads as native macOS with nothing to bundle.
@MainActor
enum FileExplorerFileIcon {
  private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
  private static var fileIcons: [String: NSImage] = [:]

  static func folder() -> NSImage { folderIcon }

  static func file(named name: String) -> NSImage {
    let ext = (name as NSString).pathExtension.lowercased()
    if let cached = fileIcons[ext] { return cached }
    // No extension or an unknown one falls back to the generic document icon.
    let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
    let icon = NSWorkspace.shared.icon(for: type ?? .data)
    fileIcons[ext] = icon
    return icon
  }
}

/// Entry cell: the file's native Finder icon beside a body-sized label with
/// middle truncation.
private final class FileExplorerEntryCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("fileExplorerEntryCell")

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let badge = NSTextField(labelWithString: "")
  private let spinner = NSProgressIndicator()
  private let warningView = NSImageView()
  /// Sweeps the label while its directory loads for the first time.
  private var shimmerLayer: CAGradientLayer?
  /// Last rendered row, replayed when the selection emphasis flips so the git
  /// tint can yield to the selected-text color.
  private var renderedName = ""
  private var renderedDecoration: GitRowDecoration?

  /// A focused, selected row draws its text over the accent fill; the fixed git
  /// tints (yellow/green/red) would clash, so defer to the selected-text color.
  private var isEmphasized: Bool { backgroundStyle == .emphasized }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet {
      guard backgroundStyle != oldValue else { return }
      applyLabel(name: renderedName, decoration: renderedDecoration)
      applyBadge(renderedDecoration)
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier
    let bodyFont = NSFont.preferredFont(forTextStyle: .body)

    // Full-color Finder icons, scaled down to the row's icon slot.
    iconView.imageScaling = .scaleProportionallyDown

    label.font = bodyFont
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    // Layer-backed so a gradient mask can drive the loading shimmer.
    label.wantsLayer = true
    // Truncation must win over widening the cell past the visible column.
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // Trailing git status glyph; font (and weight) are set per row in `configure`.
    badge.alignment = .center
    badge.setContentHuggingPriority(.required, for: .horizontal)
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    badge.isHidden = true

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    warningView.image = NSImage(
      systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Unreadable"
    )
    warningView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
    warningView.contentTintColor = .secondaryLabelColor

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    // Icon, name, and any load spinner pack at the leading edge; the trailing
    // gravity holds the git badge and the read-failure warning (mutually
    // exclusive), so whichever shows pins to the row's trailing edge.
    stack.addView(iconView, in: .leading)
    stack.addView(label, in: .leading)
    stack.addView(spinner, in: .leading)
    stack.addView(warningView, in: .trailing)
    stack.addView(badge, in: .trailing)
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      iconView.widthAnchor.constraint(equalToConstant: 16),
      iconView.heightAnchor.constraint(equalToConstant: 16),
    ])
    textField = label
    imageView = iconView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(
    with entry: FileExplorerEntry,
    isLoading: Bool,
    isShimmering: Bool,
    failure: FileExplorerListingError?,
    decoration: GitRowDecoration?
  ) {
    iconView.image = entry.isDirectory ? FileExplorerFileIcon.folder() : FileExplorerFileIcon.file(named: entry.name)
    iconView.setAccessibilityLabel(entry.isDirectory ? "Folder" : "File")
    // A read failure owns the trailing slot, so its warning wins over a badge.
    let effective = failure == nil ? decoration : nil
    renderedName = entry.name
    renderedDecoration = effective
    applyLabel(name: entry.name, decoration: effective)
    applyBadge(effective)
    // Gitignored and deleted rows fade the whole row; the deletion is already
    // called out by the strikethrough, so no distinct color is needed.
    let opacity: CGFloat = Self.isDimmed(effective) ? 0.6 : 1
    iconView.alphaValue = opacity
    label.alphaValue = opacity
    badge.alphaValue = opacity
    if isLoading {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
    setShimmering(isShimmering)
    warningView.isHidden = failure == nil
    warningView.toolTip = failure.map(Self.failureHelp)
    warningView.setAccessibilityLabel(failure.map(Self.failureHelp))
  }

  /// Tints the name by git state (green add, yellow modify, red conflict) and
  /// strikes through a deletion; ignored and deleted rows also fade via alpha.
  /// The tint and the trailing letter share one source of truth.
  private func applyLabel(name: String, decoration: GitRowDecoration?) {
    if case .file(.deleted, _)? = decoration {
      label.attributedStringValue = NSAttributedString(
        string: name,
        attributes: [
          .strikethroughStyle: NSUnderlineStyle.single.rawValue,
          .foregroundColor: isEmphasized ? NSColor.alternateSelectedControlTextColor : .labelColor,
          .font: label.font ?? NSFont.preferredFont(forTextStyle: .body),
        ]
      )
      return
    }
    label.stringValue = name
    label.textColor = labelColor(for: decoration)
  }

  private static func isDimmed(_ decoration: GitRowDecoration?) -> Bool {
    switch decoration {
    case .ignored, .file(.deleted, _): true
    default: false
    }
  }

  /// The trailing glyph: a state letter for a file (heavier weight when staged)
  /// or a collapsed directory's rollup, hidden otherwise. The tooltip spells out
  /// the state for hover and VoiceOver.
  private func applyBadge(_ decoration: GitRowDecoration?) {
    switch decoration {
    case .file(let state, let isStaged):
      badge.isHidden = false
      badge.stringValue = Self.letter(for: state)
      badge.textColor = isEmphasized ? .alternateSelectedControlTextColor : Self.tint(for: state)
      badge.font = .monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
        weight: isStaged ? .semibold : .regular
      )
      let help = Self.badgeHelp(state: state, isStaged: isStaged)
      badge.toolTip = help
      badge.setAccessibilityLabel(help)
    case .ignored, nil:
      badge.isHidden = true
      badge.toolTip = nil
      badge.setAccessibilityLabel(nil)
    }
  }

  private func labelColor(for decoration: GitRowDecoration?) -> NSColor {
    // An emphasized row draws over the accent fill, so every row (even clean or
    // ignored) yields to the selected-text color, not just the git-tinted ones.
    if isEmphasized { return .alternateSelectedControlTextColor }
    guard case .file(let state, _) = decoration else { return .labelColor }
    return Self.tint(for: state)
  }

  private static func letter(for state: GitRowDecoration.FileState) -> String {
    switch state {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    case .conflicted: "C"
    }
  }

  private static func tint(for state: GitRowDecoration.FileState) -> NSColor {
    switch state {
    case .added: .systemGreen
    case .modified: .systemYellow
    // Deletion reads through the strikethrough and row fade, not a color.
    case .deleted: .labelColor
    case .conflicted: .systemRed
    }
  }

  private static func badgeHelp(state: GitRowDecoration.FileState, isStaged: Bool) -> String {
    let staged = isStaged ? "staged" : "unstaged"
    return switch state {
    case .added: "Added, \(staged)."
    case .modified: "Modified, \(staged)."
    case .deleted: "Deleted, \(staged)."
    case .conflicted: "Merge conflict."
    }
  }

  override func layout() {
    super.layout()
    shimmerLayer?.frame = label.bounds
  }

  /// Matches `ShimmerModifier`'s look (0.6 dim floor, full-strength band); here
  /// the band sweeps by animating the gradient mask's locations.
  private func setShimmering(_ active: Bool) {
    guard active else {
      label.layer?.mask = nil
      shimmerLayer = nil
      return
    }
    // Cache only once the mask is actually installed: writing shimmerLayer when
    // label.layer is nil would wedge the guard and never shimmer this cell again.
    guard shimmerLayer == nil, let layer = label.layer else { return }
    let gradient = CAGradientLayer()
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    gradient.colors = [
      NSColor.black.withAlphaComponent(0.6).cgColor,
      NSColor.black.cgColor,
      NSColor.black.withAlphaComponent(0.6).cgColor,
    ]
    gradient.locations = [0, 0.5, 1]
    gradient.frame = label.bounds
    let sweep = CABasicAnimation(keyPath: "locations")
    sweep.fromValue = [-1.0, -0.5, 0.0]
    sweep.toValue = [1.0, 1.5, 2.0]
    sweep.duration = 1.5
    sweep.repeatCount = .infinity
    gradient.add(sweep, forKey: "shimmer")
    layer.mask = gradient
    shimmerLayer = gradient
  }

  private static func failureHelp(_ failure: FileExplorerListingError) -> String {
    switch failure {
    case .notFound: "This folder no longer exists. Expand it again to retry."
    case .permissionDenied: "Supacode doesn't have permission to read this folder. Expand it again to retry."
    case .unreadable: "Can't read this folder. Expand it again to retry."
    }
  }
}

/// Tail cell of a capped listing.
private final class FileExplorerShowMoreCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("fileExplorerShowMoreCell")

  private let button = NSButton(title: "", target: nil, action: nil)
  private var onTap: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = NSFont.preferredFont(forTextStyle: .body)
    button.contentTintColor = .secondaryLabelColor
    button.target = self
    button.action = #selector(buttonTapped)
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(remaining: Int, isLoading: Bool, onTap: @escaping () -> Void) {
    button.title = "Show \(remaining) More"
    button.isEnabled = !isLoading
    button.toolTip = "Load the next chunk of this folder's entries."
    self.onTap = onTap
  }

  @objc private func buttonTapped() {
    onTap?()
  }
}
