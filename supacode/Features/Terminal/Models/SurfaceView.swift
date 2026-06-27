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

  var onFocusChange: ((Bool) -> Void)?
  /// Asked on re-attachment to a window: should this surface re-claim
  /// firstResponder right now? SwiftUI detaches sibling surfaces during split
  /// rebuilds (e.g. after closing a surface), and AppKit doesn't auto-promote
  /// a re-attached view, so without this hook the recorded focus owner sits in
  /// the tree without listening to keystrokes. Only consulted on RE-attachment
  /// (not the first mount, unless `claimsFocusOnFirstMount`) so we never fight
  /// the initial-focus path.
  var shouldClaimFocus: (() -> Bool)?
  /// Set the first time this view lands in a real window. The self-claim path
  /// is gated on this so it only fires for the re-attachment case.
  private var hasBeenInWindow = false
  /// Outstanding self-claim Task from the most recent re-attach. Rapid split
  /// rebuilds would otherwise queue one Task per attach; cancelling the prior
  /// keeps the queue at most one deep without changing correctness (each Task
  /// is already idempotent on its own guards).
  private var pendingFocusClaim: Task<Void, Never>?

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

  /// The view that should become firstResponder when this surface re-claims
  /// focus. Defaults to the leaf itself; a subclass whose responder is an
  /// embedded descendant (e.g. a hosted NSView) overrides this.
  var focusResponder: NSView { self }

  /// Whether to claim firstResponder on the FIRST mount, not just on
  /// re-attachment. Default `false` is for surfaces whose initial focus is
  /// driven by some other path (so we don't fight it); a surface with no other
  /// initial-focus wiring overrides to `true`.
  var claimsFocusOnFirstMount: Bool { false }

  /// Walks up from `responder` to the enclosing `SurfaceView`, if any. Used to
  /// decide whether a re-attaching surface may steal focus: claiming from no
  /// owner or from another surface (or its descendants) is safe; stealing from
  /// an unrelated responder mid-rebuild would yank focus from whatever the user
  /// is actively typing into.
  static func surfaceAncestor(of responder: NSResponder?) -> SurfaceView? {
    var view = responder as? NSView
    while let current = view {
      if let surface = current as? SurfaceView { return surface }
      view = current.superview
    }
    return nil
  }

  /// Called when this surface is detached from its window. Default no-op; a
  /// subclass overrides to drop stale local focus state.
  func surfaceDidDetachFromWindow() {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      // SwiftUI can temporarily detach a surface while rebuilding split/zoom
      // layout. If we keep stale local focus state, detached surfaces still
      // intercept bindings.
      pendingFocusClaim?.cancel()
      pendingFocusClaim = nil
      surfaceDidDetachFromWindow()
    } else if hasBeenInWindow || claimsFocusOnFirstMount, shouldClaimFocus?() == true {
      // Re-attached after a split-tree rebuild dropped us. AppKit doesn't
      // auto-promote a re-attached view to firstResponder, so claim it back
      // ourselves on the next runloop tick (immediate claim is unreliable
      // when SwiftUI is mid-mount and `window` may still flip).
      let attachedWindow = window
      pendingFocusClaim?.cancel()
      pendingFocusClaim = Task { @MainActor [weak self] in
        guard
          let self,
          !Task.isCancelled,
          let window = self.window,
          window === attachedWindow,
          self.shouldClaimFocus?() == true
        else { return }
        // Only reclaim from the no-owner or sibling-surface case. Stealing
        // from an unrelated responder (command palette, inline rename text
        // field) mid-rebuild would yank focus from whatever the user is
        // actively typing into.
        let responder = window.firstResponder
        guard Self.surfaceAncestor(of: responder) !== self else { return }
        if responder == nil || Self.surfaceAncestor(of: responder) != nil {
          _ = window.makeFirstResponder(self.focusResponder)
        }
      }
    }
    if window != nil {
      hasBeenInWindow = true
    }
  }
}

/// The kind of surface a `SurfaceView` is, with its concretely-typed view.
/// Adding a case forces every `switch` on `content` to handle it.
enum SurfaceContent {
  case terminal(GhosttySurfaceView)
}
