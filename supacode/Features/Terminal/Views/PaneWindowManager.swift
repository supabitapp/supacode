import AppKit
import ComposableArchitecture
import OrderedCollections
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// A windowed pane's window; typed so app-level chrome can recognize and
/// anchor to it.
@MainActor
final class PaneWindow: NSWindow, WindowTintColorProviding {
  /// The pane this window hosts; commands arriving while this window is key
  /// target it, whatever worktree is selected.
  var hostedWorktreeID: Worktree.ID?
  var hostedPaneID: PaneID?
  /// Closes the pane's selected tab; serves the menu's Close Window item so
  /// only the red close button exits window mode.
  var closeSelectedTab: (() -> Void)?
  /// This pane's surface background, so the chrome never wears the selected
  /// worktree's color.
  var tintColor: (() -> NSColor?)?
  /// Matches app shortcut chords before normal dispatch. The menu's
  /// FocusedValue-gated items can lose their published actions while an
  /// AppKit-owned window is key, so chords are handled here deterministically.
  var performShortcut: ((NSEvent) -> Bool)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, performShortcut?(event) == true { return }
    super.sendEvent(event)
  }

}

/// Pane-scoped chord resolution, pure so tests can drive it with synthesized
/// events.
enum PaneWindowShortcut {
  enum Intent: Equatable {
    case exitWindowMode
    case newTab(ContentID)
    case closeTab(ContentID)
    case beginRename(TabID)
    case selectTab(TabID)
    case runScript
    case stopRunScripts
    /// Matched but not actionable; consumed so the chord cannot leak through.
    case ignore
  }

  static func intent(
    for event: NSEvent,
    pane: Pane,
    overrides: [AppShortcutID: AppShortcutOverride],
    isWorktreeSelected: Bool
  ) -> Intent? {
    // Chords carry at least one of these; anything else is typing for the surface.
    guard !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return nil }
    func matched(_ shortcut: AppShortcut) -> Bool {
      shortcut.effective(from: overrides)?.matches(event) == true
    }
    if matched(AppShortcuts.toggleWindowMode) {
      return event.isARepeat ? .ignore : .exitWindowMode
    }
    if matched(AppShortcuts.newTerminalTab) {
      guard !event.isARepeat, let contentID = pane.selectedTab?.content.id else { return .ignore }
      return .newTab(contentID)
    }
    if matched(AppShortcuts.closeTab) {
      guard !event.isARepeat, let contentID = pane.selectedTab?.content.id else { return .ignore }
      return .closeTab(contentID)
    }
    if matched(AppShortcuts.renameTab) {
      guard !event.isARepeat, let tab = pane.selectedTab, !tab.isTitleLocked else { return .ignore }
      return .beginRename(tab.id)
    }
    for (index, shortcut) in AppShortcuts.tabSelection.enumerated() where matched(shortcut) {
      guard !event.isARepeat, !pane.tabs.isEmpty else { return .ignore }
      // Clamped to the strip, matching the main window's semantics.
      return .selectTab(pane.tabs[min(index + 1, pane.tabs.count) - 1].id)
    }
    let isRunScript = matched(AppShortcuts.runScript)
    let isStopRunScript = matched(AppShortcuts.stopRunScript)
    if isRunScript || isStopRunScript {
      // Run scripts act on the selected worktree; consuming (not falling
      // through) keeps the chord off another worktree's script.
      guard !event.isARepeat, isWorktreeSelected else { return .ignore }
      return isRunScript ? .runScript : .stopRunScripts
    }
    // Splits, neighbor focus, zoom, and equalize are unavailable in a pane
    // window; consume them so the menu cannot apply them to the selected
    // worktree's layout instead.
    let unavailable = [
      AppShortcuts.splitRight, AppShortcuts.splitLeft, AppShortcuts.splitDown, AppShortcuts.splitUp,
      AppShortcuts.focusSplitLeft, AppShortcuts.focusSplitRight,
      AppShortcuts.focusSplitUp, AppShortcuts.focusSplitDown,
      AppShortcuts.toggleSplitZoom, AppShortcuts.equalizeSplits,
    ]
    if unavailable.contains(where: matched) {
      return .ignore
    }
    return nil
  }
}

/// Owns the windowed-pane windows: one per pane in window mode, reconciled
/// from layout state after every layout change. Closing a window exits window
/// mode; it never closes the pane.
@MainActor
final class PaneWindowManager {
  private static let logger = SupaLogger("PaneWindow")

  private struct Key: Hashable {
    let worktreeID: Worktree.ID
    let paneID: PaneID
  }

  weak var terminalManager: WorktreeTerminalManager?
  /// Re-injected past the hosting boundary; wired once by the app shell.
  var ghosttyShortcuts: GhosttyShortcutManager?
  var commandKeyObserver: CommandKeyObserver?

  @Shared(.settingsFile) private var settingsFile: SettingsFile
  private var controllers: [Key: PaneWindowController] = [:]
  private var cascadePoint = NSPoint.zero
  /// The most recent live, non-windowed focused pane per worktree; where
  /// focus returns when a pane window hands it back.
  private var lastEmbeddedFocusPaneIDs: [Worktree.ID: PaneID] = [:]
  private var appObservers: [NSObjectProtocol] = []
  private var isReconciling = false

  init() {
    // Hiding or unhiding the app fires no per-window events; re-derive every
    // windowed surface's activity so hidden windows stop rendering.
    for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      appObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.reassertAllHosts() }
        }
      )
    }
  }

  isolated deinit {
    appObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  /// Opens missing windows and closes stale ones for the worktree. A window
  /// that fails to open returns its pane inline, so it never strands behind
  /// an unreachable placeholder.
  func reconcile(worktreeID: Worktree.ID) {
    // Reentrancy guard: the failed-open recovery sends a layout action.
    guard !isReconciling else { return }
    isReconciling = true
    defer { isReconciling = false }
    guard let layout = terminalManager?.layoutState(for: worktreeID) else {
      // An unreadable layout is not "no windowed panes"; tearing down here
      // would destroy live windows. Real teardown goes through `closeAll`.
      Self.logger.error("Skipping pane-window reconcile: no layout state for \(worktreeID).")
      return
    }
    let windowed = layout.windowedPaneIDs
    if let focused = layout.layout.focusedPaneID, !windowed.contains(focused) {
      lastEmbeddedFocusPaneIDs[worktreeID] = focused
    }
    tearDownControllers(for: worktreeID, keeping: windowed)
    for paneID in windowed {
      let key = Key(worktreeID: worktreeID, paneID: paneID)
      guard controllers[key] == nil else { continue }
      guard let controller = makeController(worktreeID: worktreeID, paneID: paneID) else {
        Self.logger.error("Pane window failed to open for \(paneID.rawValue); returning the pane inline.")
        terminalManager?.sendLayout(worktreeID, .exitWindowMode(paneID: paneID))
        continue
      }
      controllers[key] = controller
      beginHeaderTracking(for: key)
      controller.showWindow(nil)
    }
  }

  /// Closes every window of a pruned worktree; its layout state is about to
  /// go, so `reconcile` will never see the panes again.
  func closeAll(for worktreeID: Worktree.ID) {
    lastEmbeddedFocusPaneIDs.removeValue(forKey: worktreeID)
    tearDownControllers(for: worktreeID)
  }

  private func tearDownControllers(for worktreeID: Worktree.ID, keeping keep: Set<PaneID> = []) {
    for (key, controller) in controllers where key.worktreeID == worktreeID && !keep.contains(key.paneID) {
      controllers.removeValue(forKey: key)
      controller.tearDown()
    }
  }

  func orderFront(worktreeID: Worktree.ID, paneID: PaneID) {
    let key = Key(worktreeID: worktreeID, paneID: paneID)
    if controllers[key] == nil {
      // A missed open retries; a second failure returns the pane inline
      // instead of absorbing the click.
      reconcile(worktreeID: worktreeID)
    }
    guard let window = controllers[key]?.window else {
      Self.logger.error("Pane window for \(paneID.rawValue) could not be reopened; exiting window mode.")
      terminalManager?.sendLayout(worktreeID, .exitWindowMode(paneID: paneID))
      return
    }
    window.makeKeyAndOrderFront(nil)
  }

  private func reassertAllHosts() {
    for worktreeID in Set(controllers.keys.map(\.worktreeID)) {
      terminalManager?.hostIfExists(for: worktreeID)?.reassertSurfaceActivity()
    }
  }

  /// Hands focus back to the layout once a pane window provably lost key to
  /// another of our windows, so the main window's surfaces do not stay
  /// unfocused behind a stale `focusedPaneID`. Deferred one tick: at resign
  /// time the new key window is not yet known, and a child panel (the
  /// palette) or an app deactivation is not a handoff.
  private func scheduleFocusReturn(for key: Key) {
    Task { @MainActor [weak self] in
      guard let self, NSApp.isActive, let window = self.controllers[key]?.window else { return }
      let newKey = NSApp.keyWindow
      // A child panel (the palette) or this window's own sheet (the close
      // confirmation) taking key is not a handoff.
      guard newKey !== window, newKey?.parent !== window, newKey?.sheetParent !== window else { return }
      self.returnFocus(for: key)
    }
  }

  /// The pane window's key state drives its surfaces' focus, which the
  /// main-window observer knows nothing about.
  private func handleKeyChange(_ isKey: Bool, for key: Key) {
    guard isKey else {
      scheduleFocusReturn(for: key)
      terminalManager?.hostIfExists(for: key.worktreeID)?.reassertSurfaceActivity()
      return
    }
    terminalManager?.sendLayout(key.worktreeID, .focusPane(.pane(key.paneID)))
    terminalManager?.hostIfExists(for: key.worktreeID)?.reassertSurfaceActivity()
    guard
      let contentID = terminalManager?.layoutState(for: key.worktreeID)?
        .layout.panes[id: key.paneID]?.selectedTab?.content.id,
      let surface = ContentRuntime.liveValue.renderer(for: contentID) as? GhosttySurfaceView
    else { return }
    surface.requestFocus()
  }

  private func returnFocus(for key: Key) {
    guard let layout = terminalManager?.layoutState(for: key.worktreeID) else { return }
    guard layout.layout.focusedPaneID == key.paneID else { return }
    // The record usually names the pane that just got windowed (it held
    // focus when it entered window mode), so a first-embedded fallback is
    // load-bearing, not defensive.
    let embedded = layout.layout.panes.filter { !layout.windowedPaneIDs.contains($0.id) }
    let remembered = lastEmbeddedFocusPaneIDs[key.worktreeID]
    guard let target = embedded.first(where: { $0.id == remembered })?.id ?? embedded.first?.id else {
      // No embedded pane exists; focus staying on the windowed pane is the
      // only consistent state.
      Self.logger.debug("Focus stays on windowed pane \(key.paneID.rawValue); no embedded pane exists.")
      return
    }
    terminalManager?.sendLayout(key.worktreeID, .focusPane(.pane(target)))
  }

  /// Dispatches a key pane window's chords to pane-scoped actions. Returns
  /// `true` when the event was consumed.
  private func handleShortcut(_ event: NSEvent, worktreeID: Worktree.ID, paneID: PaneID) -> Bool {
    guard let terminalManager else { return false }
    // Plain typing never matches a chord; bail before touching the store.
    guard !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
    guard let pane = terminalManager.layoutState(for: worktreeID)?.layout.panes[id: paneID] else {
      // The window outlived its pane; consuming here would deaden every chord.
      Self.logger.error("Pane window \(paneID.rawValue) has no pane in \(worktreeID); passing the chord through.")
      return false
    }
    let isWorktreeSelected =
      terminalManager.appStore?.withState { $0.repositories.selectedWorktreeID } == worktreeID
    let intent = PaneWindowShortcut.intent(
      for: event,
      pane: pane,
      overrides: settingsFile.global.shortcutOverrides,
      isWorktreeSelected: isWorktreeSelected
    )
    guard let intent else { return false }
    switch intent {
    case .exitWindowMode:
      terminalManager.sendLayout(worktreeID, .exitWindowMode(paneID: paneID))
    case .newTab(let contentID):
      terminalManager.sendLayout(worktreeID, .contentRequestedNewTab(content: contentID))
    case .closeTab(let contentID):
      terminalManager.sendLayout(worktreeID, .contentRequestedClose(content: contentID, scope: .tab))
    case .beginRename(let tabID):
      terminalManager.sendLayout(worktreeID, .beginTabRename(id: tabID))
    case .selectTab(let tabID):
      terminalManager.sendLayout(worktreeID, .wakeTab(id: tabID))
      terminalManager.sendLayout(worktreeID, .selectTab(id: tabID))
    case .runScript:
      terminalManager.appStore?.send(.runScript)
    case .stopRunScripts:
      terminalManager.appStore?.send(.stopRunScripts)
    case .ignore:
      break
    }
    return true
  }

  /// Recomputes the window's header line under observation tracking and
  /// re-arms on every change, so renames land without any store read in a
  /// view body.
  private func beginHeaderTracking(for key: Key) {
    guard let model = controllers[key]?.headerModel, let store = terminalManager?.appStore else { return }
    let title = withObservationTracking {
      Self.headerInfo(for: key.worktreeID, in: store.repositories)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        // Same-model check: a torn-down and reopened window would otherwise
        // fork a second tracking loop for the same key.
        guard let self, self.controllers[key]?.headerModel === model else { return }
        self.beginHeaderTracking(for: key)
      }
    }
    if model.title != title {
      model.title = title
    }
  }

  /// The header's "repository / worktree" line, mirroring the notification
  /// pane's section titles.
  private static func headerInfo(for worktreeID: Worktree.ID, in repositories: RepositoriesFeature.State) -> String {
    guard let row = repositories.sidebarItems[id: worktreeID] else { return "" }
    let worktreeName = SidebarDisplayName.resolved(custom: row.customTitle, fallback: row.name) ?? row.name
    guard let repositoryID = repositories.repositoryID(containing: worktreeID) else { return worktreeName }
    let repositoryName = Repository.sidebarDisplayName(
      custom: repositories.sidebar.sections[repositoryID]?.title,
      fallback: repositories.repositoryName(for: repositoryID) ?? "Repository"
    )
    return "\(repositoryName) / \(worktreeName)"
  }

  private func makeController(worktreeID: Worktree.ID, paneID: PaneID) -> PaneWindowController? {
    guard let terminalManager, let appStore = terminalManager.appStore else {
      Self.logger.error("Cannot open pane window without the app store.")
      return nil
    }
    guard
      let layoutStore = appStore
        .scope(state: \.terminals, action: \.terminals)
        .scope(state: \.layouts[id: worktreeID], action: \.layouts[id: worktreeID])
    else {
      Self.logger.error("Cannot open pane window for unknown layout \(worktreeID).")
      return nil
    }
    let key = Key(worktreeID: worktreeID, paneID: paneID)
    let window = PaneWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // The root view draws its own repo and worktree header; the system title
    // stays set for the window menu and assistive tech but never renders.
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    // Window mode is never persisted, so restoration has nothing to restore.
    window.isRestorable = false
    // `WindowChromeApplier` owns the background; this only avoids a default
    // titlebar flash before the first apply.
    window.titlebarAppearsTransparent = true
    window.tabbingMode = .disallowed
    window.hostedWorktreeID = worktreeID
    window.hostedPaneID = paneID
    window.closeSelectedTab = { [weak terminalManager] in
      guard
        let contentID = terminalManager?.layoutState(for: worktreeID)?
          .layout.panes[id: paneID]?.selectedTab?.content.id
      else { return }
      terminalManager?.sendLayout(worktreeID, .contentRequestedClose(content: contentID, scope: .tab))
    }
    window.tintColor = { [weak terminalManager] in
      guard
        let terminalManager,
        let contentID = terminalManager.layoutState(for: worktreeID)?
          .layout.panes[id: paneID]?.selectedTab?.content.id
      else { return nil }
      return terminalManager.surfaceBackground(forContent: contentID)
    }
    window.performShortcut = { [weak self] event in
      self?.handleShortcut(event, worktreeID: worktreeID, paneID: paneID) ?? false
    }
    window.minSize = NSSize(width: 320, height: 240)
    window.title = terminalManager.layoutState(for: worktreeID)?.layout.panes[id: paneID]
      .flatMap(WindowedPaneRootView.title(for:)) ?? "Terminal"
    window.center()
    cascadePoint = window.cascadeTopLeft(from: cascadePoint)
    let headerModel = PaneWindowHeaderModel()
    let root = WindowedPaneRootView(
      store: layoutStore,
      paneID: paneID,
      runtime: ContentRuntime.liveValue,
      manager: terminalManager,
      worktreeID: worktreeID,
      ghosttyShortcuts: ghosttyShortcuts,
      commandKeyObserver: commandKeyObserver,
      windowIsKey: { [weak window] in window?.isKeyWindow == true },
      updateWindowTitle: { [weak window] title in window?.title = title },
      header: headerModel
    )
    let hostingView = PaneWindowHostingView(rootView: root)
    // Full-size content: the header row occupies the titlebar band itself.
    hostingView.safeAreaRegions = []
    // Let the window own its size; the hosting view would otherwise drive
    // the window frame from the content's reported bounds.
    hostingView.sizingOptions = []
    window.contentView = hostingView
    return PaneWindowController(
      window: window,
      headerModel: headerModel,
      onCloseRequested: { [weak terminalManager] in
        terminalManager?.sendLayout(worktreeID, .exitWindowMode(paneID: paneID))
      },
      onKeyChanged: { [weak self] isKey in
        self?.handleKeyChange(isKey, for: key)
      },
      onActivityChanged: { [weak terminalManager] in
        terminalManager?.hostIfExists(for: worktreeID)?.reassertSurfaceActivity()
      }
    )
  }
}

/// The header line a pane window renders; the manager rewrites it under
/// observation tracking so renames land without store reads in a view body.
@MainActor
@Observable
final class PaneWindowHeaderModel {
  var title = ""
}

/// A pane window's controller: the close button exits window mode through the
/// reducer, and key, occlusion, and miniaturization changes re-derive surface
/// activity.
@MainActor
private final class PaneWindowController: NSWindowController, NSWindowDelegate {
  let headerModel: PaneWindowHeaderModel
  private let onCloseRequested: () -> Void
  private let onKeyChanged: (Bool) -> Void
  private let onActivityChanged: () -> Void

  init(
    window: NSWindow,
    headerModel: PaneWindowHeaderModel,
    onCloseRequested: @escaping () -> Void,
    onKeyChanged: @escaping (Bool) -> Void,
    onActivityChanged: @escaping () -> Void
  ) {
    self.headerModel = headerModel
    self.onCloseRequested = onCloseRequested
    self.onKeyChanged = onKeyChanged
    self.onActivityChanged = onActivityChanged
    super.init(window: window)
    window.delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// The red button exits window mode; the state change closes the window
  /// through the reconcile, so the pane itself survives.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    onCloseRequested()
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) {
    onKeyChanged(true)
  }

  func windowDidResignKey(_ notification: Notification) {
    onKeyChanged(false)
  }

  func windowDidChangeOcclusionState(_ notification: Notification) {
    onActivityChanged()
  }

  func windowDidMiniaturize(_ notification: Notification) {
    onActivityChanged()
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    onActivityChanged()
  }

  func tearDown() {
    window?.delegate = nil
    // Release the content tree, not just the window: a retained NSHostingView
    // keeps its focused values and shortcuts registered app-wide, shadowing
    // the live windows' publications.
    window?.contentView = nil
    // The window object survives `close()`; disarm its callbacks so a stray
    // event cannot dispatch actions for a pane the manager already dropped.
    if let paneWindow = window as? PaneWindow {
      paneWindow.performShortcut = nil
      paneWindow.closeSelectedTab = nil
      paneWindow.tintColor = nil
    }
    close()
  }
}

/// Even with empty `sizingOptions`, `NSHostingView` re-applies its content's
/// ideal size to the window from its window-did-layout hook, and a
/// full-size-content window's ideal tracks the whole frame, so every layout
/// pass grows the window by one titlebar height. Shadowing the hook's
/// selector lands the notification in a no-op; the window's frame is the
/// user's.
private final class PaneWindowHostingView: NSHostingView<WindowedPaneRootView> {
  @objc private func windowDidLayout() {}
}

/// The window's root: the pane strip and content in `.windowed` context, gone
/// once the pane leaves window mode or the layout. Publishes pane-scoped
/// menu actions and hosts the pane's close confirmation.
private struct WindowedPaneRootView: View {
  @Bindable var store: StoreOf<LayoutFeature>
  let paneID: PaneID
  let runtime: ContentRuntime
  let manager: WorktreeTerminalManager
  let worktreeID: Worktree.ID
  let ghosttyShortcuts: GhosttyShortcutManager?
  let commandKeyObserver: CommandKeyObserver?
  /// Perform-time guard: the scene arbitration between this window's focused
  /// values and the main scene's is undefined, so a leaked action must no-op
  /// rather than act while another window is key.
  let windowIsKey: () -> Bool
  let updateWindowTitle: (String) -> Void
  /// The manager-maintained repository and worktree line.
  let header: PaneWindowHeaderModel

  var body: some View {
    // Re-read config-derived colors on every Ghostty config reload.
    let _ = manager.configGeneration
    Group {
      if let pane = store.layout.panes[id: paneID], store.windowedPaneIDs.contains(paneID) {
        VStack(spacing: 0) {
          PaneWindowHeaderView(title: header.title)
          PaneStripView(
            pane: pane,
            windowedPaneIDs: [],
            store: store,
            runtime: runtime,
            surfaceState: { [weak manager] surfaceID in
              manager?.hostIfExists(for: worktreeID)?.surfaceStates[surfaceID]
            },
            context: .windowed
          )
        }
        .onAppear {
          updateWindowTitle(Self.title(for: pane))
        }
        .onChange(of: Self.title(for: pane)) { _, title in
          updateWindowTitle(title)
        }
        .focusedSceneAction(
          \.newTerminalAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          guard windowIsKey(), let contentID = pane.selectedTab?.content.id else { return }
          store.send(.contentRequestedNewTab(content: contentID))
        }
        .focusedSceneAction(
          \.renameTabAction,
          enabled: pane.selectedTab.map { !$0.isTitleLocked } ?? false,
          token: pane.selectedTabID
        ) {
          guard windowIsKey(), let tabID = pane.selectedTabID else { return }
          store.send(.beginTabRename(id: tabID))
        }
        .focusedAction(
          \.closeTabAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          requestCloseSelectedTab(of: pane)
        }
        .focusedAction(
          \.closeSurfaceAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          // One content per tab: closing the surface closes the tab.
          requestCloseSelectedTab(of: pane)
        }
        // Published disabled: a pane window takes no splits, zoom, or
        // neighbor focus, and the main scene's actions would otherwise hit
        // the selected worktree.
        .focusedAction(\.splitTerminalAction, enabled: false) { (_: TerminalSplitMenuDirection) in }
        .focusedAction(\.focusSplitAction, enabled: false) { (_: TerminalSplitMenuDirection) in }
        .focusedAction(\.toggleSplitZoomAction, enabled: false) {}
        .focusedAction(\.equalizeSplitsAction, enabled: false) {}
        .focusedSceneAction(\.toggleWindowModeAction, enabled: true, token: paneID.rawValue) {
          guard windowIsKey() else { return }
          store.send(.exitWindowMode(paneID: paneID))
        }
        // Search is surface-level; route it to this pane's surface so the
        // menu never searches the selected worktree's terminal instead.
        .focusedSceneAction(
          \.startSearchAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          performOnSelectedSurface(of: pane) { $0.performBindingAction("start_search") }
        }
        .focusedSceneAction(
          \.searchSelectionAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          performOnSelectedSurface(of: pane) { $0.performBindingAction("search_selection") }
        }
        .focusedSceneAction(
          \.navigateSearchNextAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          performOnSelectedSurface(of: pane) { $0.navigateSearch(.next) }
        }
        .focusedSceneAction(
          \.navigateSearchPreviousAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          performOnSelectedSurface(of: pane) { $0.navigateSearch(.previous) }
        }
        .focusedSceneAction(
          \.endSearchAction,
          enabled: pane.selectedTab != nil,
          token: pane.selectedTab?.content.id
        ) {
          performOnSelectedSurface(of: pane) { $0.performBindingAction("end_search") }
        }
      } else {
        // The reconcile closes this window on the same layout change.
        Color.clear
      }
    }
    .background {
      // Confirmations raised from this pane present here; the main layout's
      // host skips them, which matters when its worktree is not selected.
      if store.alertPaneID == paneID {
        Color.clear.alert($store.scope(state: \.alert, action: \.alert))
      }
    }
    // The same chrome stack as the main window: the backdrop carries the
    // tint minus this window's surfaces, and the observer keeps the window
    // background and appearance applied through mounts and config changes.
    .background(WindowTintBackdrop(runtime: manager.ghosttyRuntime))
    .background(WindowChromeObserver(runtime: manager.ghosttyRuntime))
    .environment(ghosttyShortcuts)
    .environment(commandKeyObserver)
  }

  private func requestCloseSelectedTab(of pane: Pane) {
    guard windowIsKey(), let contentID = pane.selectedTab?.content.id else { return }
    store.send(.contentRequestedClose(content: contentID, scope: .tab))
  }

  private func performOnSelectedSurface(of pane: Pane, _ action: (GhosttySurfaceView) -> Void) {
    guard windowIsKey(),
      let contentID = pane.selectedTab?.content.id,
      let surface = runtime.renderer(for: contentID) as? GhosttySurfaceView
    else { return }
    action(surface)
  }

  static func title(for pane: Pane) -> String {
    guard let tab = pane.selectedTab else { return "Terminal" }
    return tab.customTitle ?? tab.title
  }
}

/// The pane window's titlebar band: the repository and worktree line, drawn
/// by the content because the system title is hidden. Hit-testing stays off
/// so titlebar drags and the traffic lights work through it.
private struct PaneWindowHeaderView: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(maxWidth: .infinity)
      // Symmetric inset clears the traffic lights and keeps the line centered.
      .padding(.horizontal, 80)
      .frame(minHeight: 28)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
