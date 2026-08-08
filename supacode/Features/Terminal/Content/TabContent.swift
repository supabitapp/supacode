import AppKit

/// A tab's live content: stable identity, a renderer once the session has
/// started, and enough recorded state to snapshot across hibernation.
@MainActor
protocol TabContent: AnyObject {
  var id: ContentID { get }
  var kind: ContentKind { get }
  /// The hosted view; nil until the session starts and while hibernated.
  var renderer: NSView? { get }
  /// Whether closing now would interrupt real work (a terminal's foreground
  /// process); drives the busy-gated close confirmation.
  var isBusy: Bool { get }
  /// Spawns the session eagerly at an explicit geometry; a second call while
  /// the renderer is alive is a no-op.
  func startSession(at geometry: ContentGeometry)
  /// Tears down the renderer while the underlying session lives on, recording
  /// whatever the content needs to restore.
  func hibernate()
  /// The current persistable state, including restoration data.
  func snapshot() -> ContentSnapshot
}

extension TabContent {
  // Most content is never busy; terminals override with their process state.
  var isBusy: Bool { false }
}

/// Where in the layout a content is being created; a runtime hint for the
/// factory (terminals map it to Ghostty's surface context), never persisted.
nonisolated enum ContentOrigin: Equatable, Sendable {
  /// The first content of an empty layout.
  case first
  /// A tab added to an existing pane.
  case tab
  /// The initial tab of a freshly split pane.
  case split
  /// Content rebuilt from persisted state after a relaunch.
  case restored
}

/// Everything the factory needs to build one tab's content, kind and all.
nonisolated struct ContentRequest: Equatable, Sendable {
  var worktreeID: Worktree.ID
  var tabID: TabID
  var contentID: ContentID
  var content: ContentState
  var origin: ContentOrigin
  /// Source content whose live session seeds inheritable config (cwd, font).
  var inheritedFrom: ContentID?

  init(
    worktreeID: Worktree.ID,
    tabID: TabID,
    contentID: ContentID,
    content: ContentState,
    origin: ContentOrigin,
    inheritedFrom: ContentID? = nil
  ) {
    self.worktreeID = worktreeID
    self.tabID = tabID
    self.contentID = contentID
    self.content = content
    self.origin = origin
    self.inheritedFrom = inheritedFrom
  }
}

/// Renderless content that never starts a session; the fallback when a
/// factory cannot build the real thing, for any content kind.
@MainActor
final class InertTabContent: TabContent {
  let id: ContentID
  private let state: ContentState

  init(id: ContentID, state: ContentState) {
    self.id = id
    self.state = state
  }

  var kind: ContentKind { state.kind }

  var renderer: NSView? { nil }

  func startSession(at geometry: ContentGeometry) {}

  func hibernate() {}

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: state)
  }
}

/// Terminal content backed by a Ghostty surface. The process itself lives in
/// zmx, so hibernation only drops the renderer, never the session.
@MainActor
final class TerminalContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal

  /// Which spawn a `makeSurface` call is; one-shot inheritance (source cwd,
  /// font, split context) applies to the first only, never a re-wake.
  nonisolated enum SpawnPhase: Equatable, Sendable {
    case first
    case rewake
  }

  // Surface construction needs heavy config owned elsewhere, so it is
  // injected; it receives the current recorded state so a wake replans from
  // the hibernation-recorded grid and cwd, not the creation-time seed.
  private let makeSurface: (ContentGeometry, TerminalContentState, SpawnPhase) -> GhosttySurfaceView
  // Latest recorded terminal state, so hibernated snapshots stay truthful.
  private var state: TerminalContentState
  private var surfaceView: GhosttySurfaceView?
  private var hasSpawned = false

  init(
    id: ContentID,
    makeSurface: @escaping (ContentGeometry, TerminalContentState, SpawnPhase) -> GhosttySurfaceView,
    initialState: TerminalContentState
  ) {
    self.id = id
    self.makeSurface = makeSurface
    self.state = initialState
  }

  var renderer: NSView? { surfaceView }

  // Hibernated terminals have no live surface, so nothing is interruptible.
  var isBusy: Bool { surfaceView?.needsCloseConfirmation ?? false }

  func startSession(at geometry: ContentGeometry) {
    guard surfaceView == nil else { return }
    surfaceView = makeSurface(geometry, state, hasSpawned ? .rewake : .first)
    hasSpawned = true
  }

  func hibernate() {
    guard let surfaceView else { return }
    state = recordedState(from: surfaceView)
    surfaceView.closeSurface()
    self.surfaceView = nil
  }

  func snapshot() -> ContentSnapshot {
    guard let surfaceView else {
      return ContentSnapshot(id: id, state: .terminal(state))
    }
    return ContentSnapshot(id: id, state: .terminal(recordedState(from: surfaceView)))
  }

  // Live values when the surface can report them, else the last recorded ones.
  private func recordedState(from surfaceView: GhosttySurfaceView) -> TerminalContentState {
    TerminalContentState(
      workingDirectory: surfaceView.bridge.state.pwd ?? state.workingDirectory,
      agents: state.agents,
      frozenGrid: surfaceView.captureFrozenGrid() ?? state.frozenGrid
    )
  }
}
