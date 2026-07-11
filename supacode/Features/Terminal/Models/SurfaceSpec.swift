import Foundation

/// Value-level "what to create" descriptor for a new surface, distinct from the
/// view-level `SurfaceContent`. The creation verb carries one of these (plus a
/// `SurfacePlacement`) so "which kind" is data instead of verb spelling; adding
/// a surface kind adds a case here and the compiler forces every dispatch
/// switch to handle it.
enum SurfaceSpec: Equatable, Sendable {
  case terminal(TerminalSurfaceSpec)

  /// Convenience for the common call-site shape.
  static func terminal(input: String? = nil, runSetupScriptIfNew: Bool = false) -> SurfaceSpec {
    .terminal(TerminalSurfaceSpec(input: input, runSetupScriptIfNew: runSetupScriptIfNew))
  }
}

/// Terminal-kind creation payload.
struct TerminalSurfaceSpec: Equatable, Sendable {
  /// Command text injected into the new surface's shell once it attaches
  /// (e.g. `$EDITOR`, a deeplink-provided command).
  var input: String?
  /// Run the repository setup script when this creation is the worktree's
  /// first. Only meaningful for tab creation; splits happen inside an
  /// already-initialized worktree and ignore it.
  var runSetupScriptIfNew: Bool = false
}
