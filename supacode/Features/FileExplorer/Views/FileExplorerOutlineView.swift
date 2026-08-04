import AppKit
import SupacodeSettingsShared
import SwiftUI

/// Callbacks the outline bridge fires back into SwiftUI / the reducer.
struct FileExplorerOutlineActions {
  var toggleDirectory: (String) -> Void
  var select: (String?) -> Void
  var openFile: (URL, OpenWorktreeAction?) -> Void
  var showMore: (String) -> Void
  var quickLook: (URL) -> Void
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

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
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
    scrollView.drawsBackground = false
    context.coordinator.outlineView = outlineView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.apply(
      tree: tree,
      fileOpenActions: fileOpenActions,
      resolvedOpenAction: resolvedOpenAction,
      menuIcon: menuIcon,
      actions: actions
    )
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

    weak var outlineView: NSOutlineView?
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
      if structureChanged {
        isApplyingState = true
        refreshItems(for: tree)
        outlineView.reloadData()
        applyExpansion(tree, outlineView: outlineView)
        isApplyingState = false
      }
      applySelection(tree, outlineView: outlineView)
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

    /// Double-click and Return: directories toggle, files open in the editor.
    func activate(item: OutlineItem) {
      guard let entry = item.entry else { return }
      if entry.isDirectory {
        actions?.toggleDirectory(item.path)
      } else if let url = url(for: item.path) {
        actions?.openFile(url, nil)
      }
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
      actions?.openFile(url, nil)
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

    @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
      guard let path = sender.representedObject as? String, let url = url(for: path) else { return }
      NSWorkspace.shared.activateFileViewerSelecting([url])
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
      cell.configure(with: entry, isLoading: childNode?.isLoading ?? false, failure: childNode?.failure)
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

    // Mirror the sidebar's open section: a primary "Open with X" entry for
    // the resolved (or first) file-capable editor, then the full submenu.
    let primary =
      (resolvedOpenAction?.canOpenFiles == true ? resolvedOpenAction : nil) ?? fileOpenActions.first
    if let primary {
      let open = makeItem(
        "Open with \(primary.labelTitle)",
        action: #selector(contextMenuOpenWith(_:)),
        symbolName: "arrow.up.right.square"
      )
      open.representedObject = OpenWithPayload(path: path, action: primary)
      menu.addItem(open)
    } else {
      let open = makeItem("Open", action: #selector(contextMenuOpen(_:)), symbolName: "arrow.up.right.square")
      open.representedObject = path
      menu.addItem(open)
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

    let quickLook = makeItem("Quick Look", action: #selector(contextMenuQuickLook(_:)), symbolName: "eye")
    quickLook.representedObject = path
    menu.addItem(quickLook)
    menu.addItem(.separator())
    let reveal = makeItem(
      "Reveal in Finder", action: #selector(contextMenuRevealInFinder(_:)), symbolName: "folder"
    )
    reveal.representedObject = path
    menu.addItem(reveal)
    menu.addItem(.separator())
    let copyPathname = makeItem(
      "Copy as Pathname", action: #selector(contextMenuCopyPathname(_:)), symbolName: "doc.on.doc"
    )
    copyPathname.representedObject = path
    menu.addItem(copyPathname)
    let copyRelative = makeItem(
      "Copy Relative Path", action: #selector(contextMenuCopyRelativePath(_:)), symbolName: "doc.on.doc"
    )
    copyRelative.representedObject = path
    menu.addItem(copyRelative)
  }

  private func makeItem(_ title: String, action: Selector, symbolName: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    return item
  }
}

/// Outline subclass adding Return-to-activate and Space-to-Quick-Look.
private final class FileExplorerNSOutlineView: NSOutlineView {
  weak var coordinator: FileExplorerOutlineView.Coordinator?

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

/// Entry cell matching the sidebar's visual language: semibold SF symbol at
/// 0.6 opacity, body-sized label with middle truncation.
private final class FileExplorerEntryCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("fileExplorerEntryCell")

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let spinner = NSProgressIndicator()
  private let warningView = NSImageView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier
    let bodyFont = NSFont.preferredFont(forTextStyle: .body)

    iconView.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: bodyFont.pointSize, weight: .semibold
    )
    iconView.contentTintColor = .secondaryLabelColor
    iconView.alphaValue = 0.6

    label.font = bodyFont
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1

    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    warningView.image = NSImage(
      systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Unreadable"
    )
    warningView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
    warningView.contentTintColor = .secondaryLabelColor

    let stack = NSStackView(views: [iconView, label, spinner, warningView])
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      iconView.widthAnchor.constraint(equalToConstant: 16),
    ])
    textField = label
    imageView = iconView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(with entry: FileExplorerEntry, isLoading: Bool, failure: FileExplorerListingError?) {
    iconView.image = NSImage(
      systemSymbolName: entry.isDirectory ? "folder" : "doc",
      accessibilityDescription: entry.isDirectory ? "Folder" : "File"
    )
    label.stringValue = entry.name
    if isLoading {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }
    warningView.isHidden = failure == nil
    warningView.toolTip = failure.map(Self.failureHelp)
    warningView.setAccessibilityLabel(failure.map(Self.failureHelp))
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet {
      // Full-strength icon only while the row is emphasized, like the sidebar.
      iconView.alphaValue = backgroundStyle == .emphasized ? 1 : 0.6
    }
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
