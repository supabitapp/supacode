import Dependencies
import Foundation

public nonisolated let secondsPerDay: TimeInterval = 86400

/// Read-only view over archived-worktree timestamps used by the
/// settings auto-delete affected-count preflight. The canonical
/// source of truth is `@Shared(.sidebar)`, which is declared in the
/// `supacode` app module and therefore out of reach of this shared
/// package. The app overrides `liveValue` at startup to bridge the
/// sidebar bucket into this package; tests inject timestamps
/// directly.
public nonisolated struct ArchivedWorktreeDatesClient: Sendable {
  public var load: @Sendable () -> [Date]

  public init(load: @escaping @Sendable () -> [Date]) {
    self.load = load
  }
}

extension ArchivedWorktreeDatesClient: DependencyKey {
  /// `unimplemented` surfaces a runtime warning in debug and fails
  /// tests if nobody registered the real reader — the settings
  /// package can't reach `@Shared(.sidebar)` itself, so the app
  /// module MUST override this in `supacodeApp.makeStore(_:)`. The
  /// `placeholder: []` keeps release builds behaving like a user
  /// with no archived worktrees rather than crashing if the
  /// override is ever dropped.
  public static let liveValue = ArchivedWorktreeDatesClient(
    load: unimplemented("ArchivedWorktreeDatesClient.load", placeholder: [])
  )

  public static let testValue = ArchivedWorktreeDatesClient(
    load: unimplemented("ArchivedWorktreeDatesClient.load", placeholder: [])
  )
}

extension DependencyValues {
  public var archivedWorktreeDatesClient: ArchivedWorktreeDatesClient {
    get { self[ArchivedWorktreeDatesClient.self] }
    set { self[ArchivedWorktreeDatesClient.self] = newValue }
  }
}
