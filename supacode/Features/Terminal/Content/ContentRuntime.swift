import AppKit
import ComposableArchitecture
import SupacodeSettingsShared

/// Reference-world registry of live contents; the value-world layout stores
/// only `ContentID`s and resolves renderers here.
@MainActor
final class ContentRuntime {
  private static let logger = SupaLogger("ContentRuntime")

  private(set) var contents: [ContentID: any TabContent] = [:]
  /// Tombstones for contents whose async kill is still in flight; a tombstoned
  /// ID cannot be re-provisioned until `confirmKill` clears it.
  private(set) var pendingKill: Set<ContentID> = []

  nonisolated init() {}

  /// Registers `content` and starts its session synchronously, exactly once.
  /// Refuses IDs that are tombstoned or already registered.
  func provision(_ content: any TabContent, at geometry: ContentGeometry) -> Bool {
    guard !pendingKill.contains(content.id) else {
      Self.logger.warning("Refused provisioning tombstoned content \(content.id.rawValue)")
      return false
    }
    guard contents[content.id] == nil else {
      Self.logger.warning("Refused provisioning already-registered content \(content.id.rawValue)")
      return false
    }
    contents[content.id] = content
    content.startSession(at: geometry)
    return true
  }

  /// The registered content's renderer; nil when unknown or hibernated.
  /// Read-only: never creates.
  func renderer(for id: ContentID) -> NSView? {
    contents[id]?.renderer
  }

  /// Spawn geometry for content created next to `id`: the source's mounted
  /// renderer, else the caller's deterministic fallback content, else the
  /// shared window/screen fallback chain.
  func spawnGeometry(near id: ContentID?, fallback fallbackID: ContentID? = nil) -> ContentGeometry {
    ContentGeometry.resolve(anchors: [
      id.flatMap { contents[$0]?.renderer },
      fallbackID.flatMap { contents[$0]?.renderer },
    ])
  }

  func content(for id: ContentID) -> (any TabContent)? {
    contents[id]
  }

  /// Unregisters and tears the content down; when `tombstone` is true the ID
  /// is blocked from re-provisioning until the caller's async kill lands and
  /// `confirmKill` clears it.
  func remove(_ id: ContentID, tombstone: Bool) {
    contents[id]?.tearDown()
    contents[id] = nil
    guard tombstone else { return }
    pendingKill.insert(id)
  }

  /// Clears a tombstone once the async kill completed.
  func confirmKill(_ id: ContentID) {
    pendingKill.remove(id)
  }
}

extension ContentRuntime: DependencyKey {
  // Stored nonisolated `let` so reducers resolve the shared registry
  // synchronously; the nonisolated init makes the off-actor creation safe.
  nonisolated static let liveValue = ContentRuntime()

  nonisolated static var testValue: ContentRuntime { ContentRuntime() }
}

extension DependencyValues {
  var contentRuntime: ContentRuntime {
    get { self[ContentRuntime.self] }
    set { self[ContentRuntime.self] = newValue }
  }
}
