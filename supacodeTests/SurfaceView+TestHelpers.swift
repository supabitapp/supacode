@testable import supacode

extension SurfaceView {
  /// Test convenience: the terminal-backed surface for this leaf. The terminal
  /// suites only ever create terminal leaves, so this force-unwraps the content
  /// kind. When a new leaf kind is added, the `switch` here forces a decision.
  var terminalForTesting: GhosttySurfaceView {
    switch content {
    case .terminal(let surface): surface
    }
  }
}
