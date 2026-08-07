import AppKit

/// A tab's live content: stable identity, a renderer once the session has
/// started, and enough recorded state to snapshot across hibernation.
@MainActor
protocol TabContent: AnyObject {
  var id: ContentID { get }
  var kind: ContentKind { get }
  /// The hosted view; nil until the session starts and while hibernated.
  var renderer: NSView? { get }
  /// Spawns the session eagerly at an explicit geometry; a second call while
  /// the renderer is alive is a no-op.
  func startSession(at geometry: ContentGeometry)
  /// Tears down the renderer while the underlying session lives on, recording
  /// whatever the content needs to restore.
  func hibernate()
  /// The current persistable state, including restoration data.
  func snapshot() -> ContentSnapshot
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

/// Everything the factory needs to build one tab's content.
nonisolated struct ContentRequest: Equatable, Sendable {
  var worktreeID: Worktree.ID
  var tabID: TerminalTabID
  var contentID: ContentID
  var initialState: TerminalContentState
  var origin: ContentOrigin
}

/// Renderless content that never starts a session; the fallback when a
/// factory cannot build the real thing.
@MainActor
final class InertTabContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal
  private let state: TerminalContentState

  init(id: ContentID, state: TerminalContentState) {
    self.id = id
    self.state = state
  }

  var renderer: NSView? { nil }

  func startSession(at geometry: ContentGeometry) {}

  func hibernate() {}

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .terminal(state))
  }
}

/// Terminal content backed by a Ghostty surface. The process itself lives in
/// zmx, so hibernation only drops the renderer, never the session.
@MainActor
final class TerminalContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal

  // Surface construction needs heavy config owned elsewhere, so it is injected.
  private let makeSurface: (ContentGeometry) -> GhosttySurfaceView
  // Latest recorded terminal state, so hibernated snapshots stay truthful.
  private var state: TerminalContentState
  private var surfaceView: GhosttySurfaceView?

  init(
    id: ContentID,
    makeSurface: @escaping (ContentGeometry) -> GhosttySurfaceView,
    initialState: TerminalContentState
  ) {
    self.id = id
    self.makeSurface = makeSurface
    self.state = initialState
  }

  var renderer: NSView? { surfaceView }

  func startSession(at geometry: ContentGeometry) {
    guard surfaceView == nil else { return }
    surfaceView = makeSurface(geometry)
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
