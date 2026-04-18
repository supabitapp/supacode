import Dependencies
import Foundation
import OrderedCollections
import Sharing
import SupacodeSettingsShared

/// One-shot migration that folds the six legacy sidebar-state
/// sources into the new `sidebar.json` file on first launch of the
/// new schema.
///
/// Reads from:
/// - `@Shared(.appStorage("sidebarCollapsedRepositoryIDs"))` — legacy
///   flat list of repo IDs whose sidebar section was collapsed.
/// - `@Shared(.appStorage("repositoryOrderIDs"))` — legacy user-
///   curated repo-row order.
/// - `@Shared(.appStorage("worktreeOrderByRepository"))` — legacy
///   per-repo unpinned worktree-row order.
/// - `@Shared(.appStorage("lastFocusedWorktreeID"))` — legacy focused
///   worktree ID.
/// - `@Shared(.appStorage("archivedWorktreeDates"))` — legacy
///   archived-worktree timestamps dictionary.
/// - `@Shared(.settingsFile).pinnedWorktreeIDs` — the modernised
///   pinned list already living in `settings.json`.
///
/// Writes to:
/// - `~/.supacode/sidebar.json` via the shared
///   `\.settingsFileStorage` dependency — always, even when the
///   migrated state is empty. The file's presence is the sole
///   idempotency signal on future launches, so we always create it.
///
/// Idempotency is file-based only. If `sidebar.json` exists we skip
/// — including on the downgrade → re-upgrade path, where the older
/// build may have re-populated the legacy UserDefaults blobs but
/// cannot have removed the file we wrote.
///
/// Ordering: the new `sidebar.json` is written FIRST; the legacy
/// sources are cleared AFTER. `SettingsFileStorage.save` is atomic,
/// so a crash before the write lands leaves the legacy sources
/// intact for the next launch to retry. A crash between write and
/// clear leaves orphan UserDefaults blobs that no live reader
/// touches (the file gates everything), so they're inert. Worst
/// case: orphaned UserDefaults storage, not lost curation.
enum SidebarPersistenceMigrator {
  private static let logger = SupaLogger("SidebarMigration")

  @MainActor
  static func migrateIfNeeded(
    fileExists: (URL) -> Bool = { url in
      FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
  ) {
    let sidebarURL = SupacodePaths.sidebarURL
    if fileExists(sidebarURL) {
      return
    }

    // Legacy UserDefaults blobs are keyed on `Repository.ID = String`
    // (bare filesystem paths). Decode explicitly as `[String]` /
    // `[String: [String]]` to keep the migrator decoupled from any
    // future rename of `Repository.ID`.
    @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) var legacyCollapsed: [String] = []
    @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
    @Shared(.appStorage("worktreeOrderByRepository")) var legacyWorktreeOrder: [String: [String]] = [:]
    @Shared(.appStorage("lastFocusedWorktreeID")) var legacyFocus: String? = nil
    @Shared(.appStorage("archivedWorktreeDates")) var legacyArchived: [String: Date] = [:]
    @Shared(.settingsFile) var settingsFile

    let legacyPinnedSet = Set(settingsFile.pinnedWorktreeIDs)
    let legacyRoots = settingsFile.repositoryRoots

    var state = SidebarState()

    // Seed ordered sections from the repo-order list first so the
    // user's curated row order is preserved as `OrderedDictionary`
    // insertion order.
    for raw in legacyOrder {
      guard let id = translate(raw) else {
        continue
      }
      state.sections[id] = .init()
    }

    // Fold per-repo unpinned worktree order into `.pinned` /
    // `.unpinned` buckets. Entries that also appear in
    // `legacyPinnedSet` route to `.pinned`.
    for (rawRepoID, worktreeIDs) in legacyWorktreeOrder {
      guard let repoID = translate(rawRepoID) else {
        continue
      }
      for worktreeID in worktreeIDs {
        let bucketID: SidebarState.Bucket.ID =
          legacyPinnedSet.contains(worktreeID) ? .pinned : .unpinned
        state.insert(worktree: worktreeID, in: repoID, bucket: bucketID)
      }
    }

    // Rescue pinned worktrees that didn't appear in the row-order
    // map (their repo had no curated order). Prefix-match the path
    // against known roots to find the owning repo. Unplaceable
    // entries log a warning with the drop count.
    var placedPinned: Set<Worktree.ID> = []
    for section in state.sections.values {
      if let pinned = section.buckets[.pinned]?.items.keys {
        placedPinned.formUnion(pinned)
      }
    }
    var unplacedPinned = 0
    for pinnedID in legacyPinnedSet where !placedPinned.contains(pinnedID) {
      if let repoID = repositoryID(owningWorktreeID: pinnedID, amongLegacyRoots: legacyRoots) {
        state.insert(worktree: pinnedID, in: repoID, bucket: .pinned)
      } else {
        unplacedPinned += 1
      }
    }
    if unplacedPinned > 0 {
      logger.warning(
        "Dropped \(unplacedPinned) orphan pinned worktree(s) whose owning repo could not be determined."
      )
    }

    // Apply the collapsed bit. May introduce a new section entry
    // if the repo was collapsed but had no curated order.
    for raw in legacyCollapsed {
      guard let id = translate(raw) else {
        continue
      }
      var section = state.sections[id] ?? .init()
      section.collapsed = true
      state.sections[id] = section
    }

    // Fold archived timestamps. First try a section that already
    // references the worktree; fall back to prefix-matching a
    // known root. Unplaceable entries drop with a warning.
    var unplacedArchived = 0
    for (archivedWorktreeID, archivedAt) in legacyArchived {
      let owningRepoID =
        state.sections.first(where: { _, section in
          section.buckets.values.contains(where: { $0.items[archivedWorktreeID] != nil })
        })?.key
        ?? repositoryID(owningWorktreeID: archivedWorktreeID, amongLegacyRoots: legacyRoots)
      guard let owningRepoID else {
        unplacedArchived += 1
        continue
      }
      // Clear the worktree from `.pinned` / `.unpinned` then
      // insert into `.archived` with the timestamp. Three explicit
      // removes beats a scan.
      state.remove(worktree: archivedWorktreeID, in: owningRepoID, from: .pinned)
      state.remove(worktree: archivedWorktreeID, in: owningRepoID, from: .unpinned)
      state.insert(
        worktree: archivedWorktreeID,
        in: owningRepoID,
        bucket: .archived,
        item: .init(archivedAt: archivedAt)
      )
    }
    if unplacedArchived > 0 {
      logger.warning(
        "Dropped \(unplacedArchived) orphan archived worktree(s) whose owning repo could not be determined."
      )
    }

    state.focusedWorktreeID = legacyFocus

    // Atomic write of the new nested shape. `storage.save` writes
    // via temp+rename, so the file either exists completely or
    // not at all. Bypass the `@Shared(.sidebar)` cache so the
    // SharedKey doesn't hydrate with an empty `SidebarState()`
    // before the real contents land on disk.
    do {
      @Dependency(\.settingsFileStorage) var storage
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(state)
      try storage.save(data, sidebarURL)
    } catch {
      logger.warning("Failed to write sidebar.json during migration: \(error)")
      return
    }

    // Clear legacy sources only after the new file landed. A
    // crash in this window leaves orphan UserDefaults blobs that
    // no live reader touches on next launch (the file gate
    // short-circuits before any legacy read runs).
    if !legacyCollapsed.isEmpty {
      $legacyCollapsed.withLock { $0 = [] }
    }
    if !legacyOrder.isEmpty {
      $legacyOrder.withLock { $0 = [] }
    }
    if !legacyWorktreeOrder.isEmpty {
      $legacyWorktreeOrder.withLock { $0 = [:] }
    }
    if legacyFocus != nil {
      $legacyFocus.withLock { $0 = nil }
    }
    if !legacyPinnedSet.isEmpty {
      $settingsFile.withLock { $0.pinnedWorktreeIDs = [] }
    }
    if !legacyArchived.isEmpty {
      $legacyArchived.withLock { $0 = [:] }
    }

    logger.info(
      """
      Migrated sidebar state: \(state.sections.count) section(s), \
      \(legacyPinnedSet.count) pinned worktree(s), \
      \(legacyArchived.count) archived worktree(s), \
      focus=\(state.focusedWorktreeID ?? "nil").
      """
    )
  }

  /// Normalise a legacy raw identifier to the canonical path shape
  /// `Repository.ID` uses at rest. Returns `nil` for empty inputs
  /// or strings with an obvious non-filesystem scheme so bogus
  /// entries don't become bogus `.sections` keys.
  static func translate(_ raw: String) -> Repository.ID? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    // Anything with a `://` that isn't a path is from a scheme this
    // build doesn't recognise — drop it so we don't pollute the new
    // `sidebar.json` with unknown entries.
    if !trimmed.hasPrefix("/"), trimmed.contains("://") {
      return nil
    }
    return URL(filePath: trimmed).standardizedFileURL.path(percentEncoded: false)
  }

  /// Recover the owning `Repository.ID` for a legacy flat worktree
  /// ID (a filesystem path) by prefix-matching against the list of
  /// known repo roots. Returns the longest matching root so nested
  /// repos win when both are registered. Returns `nil` when no
  /// root is a parent prefix of the worktree.
  static func repositoryID(
    owningWorktreeID worktreeID: Worktree.ID,
    amongLegacyRoots legacyRoots: [String]
  ) -> Repository.ID? {
    let normalisedWorktreePath = URL(filePath: worktreeID)
      .standardizedFileURL
      .path(percentEncoded: false)
    var bestMatch: (path: String, length: Int)?
    for rawRoot in legacyRoots {
      // `URL(filePath:).standardizedFileURL.path(percentEncoded:)`
      // on macOS preserves trailing slashes, so strip them before
      // appending the directory separator below — otherwise
      // "/repo-a/" concatenates to "/repo-a//" and matches nothing.
      let normalisedRoot = URL(filePath: rawRoot)
        .standardizedFileURL
        .path(percentEncoded: false)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !normalisedRoot.isEmpty else {
        continue
      }
      let rootWithLeadingSlash = "/" + normalisedRoot
      // The worktree path should sit under the root's directory;
      // the trailing slash guards against a spurious match where
      // one root is a non-directory prefix of another.
      guard normalisedWorktreePath.hasPrefix(rootWithLeadingSlash + "/") else {
        continue
      }
      if rootWithLeadingSlash.count > (bestMatch?.length ?? 0) {
        bestMatch = (rootWithLeadingSlash, rootWithLeadingSlash.count)
      }
    }
    return bestMatch?.path
  }
}
