import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

/// Stable identity for the sidebar `SharedKey`. Mirrors
/// `LayoutsKeyID` — a dummy struct so `SharedKey.id` can
/// discriminate this key from every other `SharedKey` in the app.
nonisolated struct SidebarKeyID: Hashable, Sendable {}

/// Custom `SharedKey` that persists `SidebarState` to `UserDefaults`. Sidebar
/// curation is internal state, not a user-editable file, so it lives in the
/// `\.defaultAppStorage` suite alongside the sidebar view toggles. The
/// relocation migrator seeds this key from a legacy `sidebar.json` once.
nonisolated struct SidebarKey: SharedKey {
  private static let logger = SupaLogger("Sidebar")

  /// UserDefaults key holding the encoded `SidebarState`.
  static let storageKey = "sidebarState"

  var id: SidebarKeyID { SidebarKeyID() }

  func load(
    context _: LoadContext<SidebarState>,
    continuation: LoadContinuation<SidebarState>
  ) {
    @Dependency(\.defaultAppStorage) var store
    guard let data = store.data(forKey: Self.storageKey) else {
      // Absent on first run and on installs whose legacy state hasn't migrated.
      continuation.resumeReturningInitialValue()
      return
    }
    do {
      continuation.resume(returning: try JSONDecoder().decode(SidebarState.self, from: data))
    } catch {
      // Preserve the undecodable bytes under a recovery key before falling back to
      // empty, so a corrupt or newer-schema (downgrade) blob survives the next save.
      Self.logger.warning("Failed to decode sidebar state from UserDefaults: \(error)")
      store.set(data, forKey: Self.storageKey + ".corrupt")
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<SidebarState>,
    subscriber _: SharedSubscriber<SidebarState>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: SidebarState,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.defaultAppStorage) var store
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      store.set(try encoder.encode(value), forKey: Self.storageKey)
      continuation.resume()
    } catch {
      Self.logger.error("Failed to persist sidebar state to UserDefaults: \(error)")
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == SidebarKey.Default {
  static var sidebar: Self {
    Self[SidebarKey(), default: SidebarState()]
  }
}

/// Typed AppStorage handle for the View menu's "Nest Worktrees by Branch"
/// toggle. Centralising the key + default here keeps the four read sites
/// (reducer State, View menu binding, sidebar view, bottom-card host) from
/// drifting on either the key string or the default value.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  static var sidebarNestWorktreesByBranch: Self {
    Self[.appStorage("sidebarNestWorktreesByBranch"), default: true]
  }

  /// "Group Pinned Rows" view-menu toggle. When on, pinned rows from every
  /// repository are hoisted into a single Pinned section at the top of the
  /// sidebar. Defaults to on so the feature is discoverable on first launch.
  static var sidebarGroupPinnedRows: Self {
    Self[.appStorage("sidebarGroupPinnedRows"), default: true]
  }

  /// "Group Active Rows" view-menu toggle. When on, rows with unread
  /// notifications / agents / awaiting input / running scripts are hoisted
  /// into a single Active section at the top of the sidebar.
  static var sidebarGroupActiveRows: Self {
    Self[.appStorage("sidebarGroupActiveRows"), default: true]
  }

  /// "Sort by Name" view-menu toggle. When on, repository and
  /// folder sections render A–Z by sidebar display name. The persisted
  /// `sidebar.sections` drag order is left alone so turning the toggle off
  /// restores the curated list. Defaults off so an existing manual order is
  /// not silently rewritten on upgrade.
  static var sidebarSortRepositoriesByName: Self {
    Self[.appStorage("sidebarSortRepositoriesByName"), default: false]
  }
}
