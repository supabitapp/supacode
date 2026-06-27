import AppKit

/// Content-agnostic leaf of a tab's `SplitTree`. `GhosttySurfaceView` is the only
/// subclass today; additional surface kinds become peer subclasses. The leaf *is*
/// the real content view (first responder, drag source, AX node), so there is no
/// wrapper box and nothing to forward.
///
/// Kind-specific code routes through `content` so adding a new leaf kind breaks
/// the build at every site that must handle it, rather than silently failing an
/// `as?` downcast.
class SurfaceView: NSView, Identifiable {
  let id: UUID

  init(id: UUID) {
    self.id = id
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // Abstract base hook — every concrete leaf overrides this.
  var content: SurfaceContent {
    fatalError("SurfaceView.content must be overridden by a concrete subclass")
  }
}

/// The kind of surface a `SurfaceView` is, with its concretely-typed view.
/// Adding a case forces every `switch` on `content` to handle it.
enum SurfaceContent {
  case terminal(GhosttySurfaceView)
}
