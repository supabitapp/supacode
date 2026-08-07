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
