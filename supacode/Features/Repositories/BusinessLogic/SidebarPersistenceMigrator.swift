import Dependencies
import Foundation
import OrderedCollections
import Sharing
import SupacodeSettingsShared

/// One-shot migration that folds the seven legacy sidebar-state
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
/// - `@Shared(.appStorage("archivedWorktreeIDs"))` — pre-#214
///   archived-worktree ID list (no timestamps). Stamped with the
///   current date to preserve the behaviour of the retired
///   `ArchivedWorktreeDatesClient.liveValue.load` one-shot fold.
/// - `@Shared(.settingsFile).pinnedWorktreeIDs` — the modernised
///   pinned list already living in `settings.json`.
///
/// Writes to:
/// - `~/.supacode/sidebar.json` via the shared
///   `\.settingsFileStorage` dependency — always, even when the
///   migrated state is empty. The file's presence is the sole
///   idempotency signal on future launches, so we always create it.
///
/// Idempotency is gated on the persisted `schemaVersion`. If
/// `sidebar.json` exists, decodes cleanly, AND carries
/// `schemaVersion >= 1` we skip — including on the downgrade →
/// re-upgrade path, where the older build may have re-populated the
/// legacy UserDefaults blobs but cannot have stamped a migrated
/// schema version on the file. A mere "file exists" check is not
/// enough: if `storage.save(…)` ever failed mid-migration (disk
/// full / permissions / iCloud hiccup) and the first
/// `@Shared(.sidebar)` mutation wrote an empty `SidebarState()`
/// (which defaults `schemaVersion` to `0`), a file-existence gate
/// would short-circuit forever and strand the user's legacy state.
/// Gating on `schemaVersion >= 1` lets the migrator retry in that
/// corner case.
///
/// Ordering: the new `sidebar.json` is written FIRST (with
/// `schemaVersion = 1`); the legacy sources are cleared AFTER.
/// `SettingsFileStorage.save` is atomic, so a crash before the
/// write lands leaves the legacy sources intact for the next
/// launch to retry. A crash between write and clear leaves orphan
/// UserDefaults blobs that no live reader touches (the file gates
/// everything), so they're inert. Worst case: orphaned
/// UserDefaults storage, not lost curation.
///
/// Pre-#214 straggler handling: the main schema-version gate is
/// bypassed for a second time if the legacy pre-#214
/// `archivedWorktreeIDs` list is non-empty on disk. The fold that
/// used to live in `ArchivedWorktreeDatesClient.liveValue.load`
/// was retired during the current branch cleanup, so this migrator
/// is the last reader of that key. We run the ID-list fold inline
/// here regardless of the main gate, stamp `Date.now` on each
/// entry (matching the retired client), and clear only after the
/// `sidebar.json` write lands.
enum SidebarPersistenceMigrator {
  private static let logger = SupaLogger("SidebarMigration")

  /// Runs the one-shot migration if `sidebar.json` is missing,
  /// corrupt, or stamped with a pre-migration `schemaVersion`.
  ///
  /// - Note: reads `@Shared(.settingsFile)` synchronously; the
  ///   `SettingsFile` SharedKey must hydrate synchronously on first
  ///   access for `pinnedWorktreeIDs` and `repositoryRoots` to make
  ///   it into `sidebar.json`. If that invariant ever changes, this
  ///   call-site must be reordered to run after the settings file
  ///   has finished loading.
  @MainActor
  static func migrateIfNeeded(
    fileExists: (URL) -> Bool = { url in
      FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    },
    readFile: (URL) -> Data? = { url in
      try? Data(contentsOf: url)
    }
  ) {
    let sidebarURL = SupacodePaths.sidebarURL

    // Legacy UserDefaults blobs are keyed on `Repository.ID = String`
    // (bare filesystem paths). Decode explicitly as `[String]` /
    // `[String: [String]]` to keep the migrator decoupled from any
    // future rename of `Repository.ID`.
    @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) var legacyCollapsed: [String] = []
    @Shared(.appStorage("repositoryOrderIDs")) var legacyOrder: [String] = []
    @Shared(.appStorage("worktreeOrderByRepository")) var legacyWorktreeOrder: [String: [String]] = [:]
    @Shared(.appStorage("lastFocusedWorktreeID")) var legacyFocus: String?
    @Shared(.appStorage("archivedWorktreeDates")) var legacyArchived: [String: Date] = [:]
    @Shared(.appStorage("archivedWorktreeIDs")) var legacyArchivedIDs: [String] = []
    @Shared(.settingsFile) var settingsFile

    let skipMain = shouldSkipMigration(
      sidebarURL: sidebarURL,
      fileExists: fileExists,
      readFile: readFile
    )

    // Pre-#214 straggler path: the retired
    // `ArchivedWorktreeDatesClient.liveValue.load` used to fold the
    // `[String]` list into `archivedWorktreeDates` on first read.
    // We inherit that job. If the main migration already ran
    // (`schemaVersion >= 1`) but the user had a stale ID list sitting
    // in UserDefaults, still fold+clear it so we don't strand those
    // archive records. Matches the retired client's `Date.now`
    // stamp so timestamps line up with the cut-over moment.
    if skipMain {
      foldLegacyArchivedIDsIntoDictionaryStorage(
        legacyArchivedIDs: $legacyArchivedIDs,
        legacyArchived: $legacyArchived
      )
      return
    }

    @Dependency(\.date.now) var now
    let legacyRoots = RepositoryPathNormalizer.normalize(settingsFile.repositoryRoots)
    let legacyPinnedSet = Set(RepositoryPathNormalizer.normalize(settingsFile.pinnedWorktreeIDs))
    // Merge the pre-#214 ID list into the dated dictionary view
    // BEFORE the fold pass so both sources land in the same
    // `SidebarState.archived` bucket in one shot. `Date.now` matches
    // the retired client's stamp. The dated entry wins on collision
    // (authoritative because #214+ timestamps are real, not synthetic).
    let mergedArchived = mergeLegacyArchivedIDs(
      legacyArchivedIDs: legacyArchivedIDs,
      legacyArchived: legacyArchived,
      stampedAt: now
    )

    var state = SidebarState()
    // Stamp the migrated schema version up-front so every code path
    // below — including any early `return` that still writes — emits
    // a `schemaVersion >= 1` file and keeps the idempotency gate
    // above honest.
    state.schemaVersion = 1

    seedSections(
      into: &state,
      legacyRoots: legacyRoots,
      legacyOrder: legacyOrder,
      legacyWorktreeOrder: legacyWorktreeOrder,
      legacyPinnedSet: legacyPinnedSet
    )
    // Build the candidate pool once so `rescueOrphanPinned` and
    // `foldArchived` share an identical view. Candidates cover every
    // filesystem location a worktree may legitimately live under
    // (repo root itself, global-override base, per-repo override
    // base, default `~/.supacode/repos/<name>/` convention) so
    // prefix resolution works even when the worktree tree and the
    // repo-root tree share no common ancestor.
    let candidates = rootCandidates(legacyRoots: legacyRoots, settingsFile: settingsFile)
    rescueOrphanPinned(
      into: &state,
      legacyPinnedSet: legacyPinnedSet,
      rootCandidates: candidates
    )
    applyCollapsedFlags(into: &state, legacyCollapsed: legacyCollapsed)
    foldArchived(into: &state, legacyArchived: mergedArchived, rootCandidates: candidates)

    state.focusedWorktreeID = legacyFocus.flatMap(RepositoryPathNormalizer.normalize)

    guard persist(state: state, to: sidebarURL) else {
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
    if !legacyArchivedIDs.isEmpty {
      $legacyArchivedIDs.withLock { $0 = [] }
    }

    logger.info(
      """
      Migrated sidebar state: \(state.sections.count) section(s), \
      \(legacyPinnedSet.count) pinned worktree(s), \
      \(mergedArchived.count) archived worktree(s), \
      focus=\(state.focusedWorktreeID ?? "nil").
      """
    )
  }

  /// Decodes the existing `sidebar.json` (if present) and returns
  /// `true` when it already carries a migrated `schemaVersion`.
  /// Any other state (missing file, decode failure,
  /// `schemaVersion == 0`) means either a fresh install, a corrupt
  /// file (the SharedKey's read path owns rename-aside handling;
  /// the migrator overwrites it below), or a prior failed migration
  /// that needs to re-run — all of which return `false` here.
  private static func shouldSkipMigration(
    sidebarURL: URL,
    fileExists: (URL) -> Bool,
    readFile: (URL) -> Data?
  ) -> Bool {
    guard fileExists(sidebarURL),
      let data = readFile(sidebarURL),
      let existing = try? JSONDecoder().decode(SidebarState.self, from: data)
    else {
      return false
    }
    return existing.schemaVersion >= 1
  }

  /// Merge the pre-#214 `[String]` archived-ID list into the dated
  /// `[String: Date]` dictionary, stamping every straggler with
  /// `stampedAt` so later passes (`foldArchived`) only need to
  /// read one source. The dated dictionary wins on collision —
  /// #214+ timestamps are real and authoritative, the ID-list
  /// stamp is synthetic.
  private static func mergeLegacyArchivedIDs(
    legacyArchivedIDs: [String],
    legacyArchived: [String: Date],
    stampedAt: Date
  ) -> [String: Date] {
    var merged = legacyArchived
    for rawID in legacyArchivedIDs {
      guard let normalizedID = RepositoryPathNormalizer.normalize(rawID) else {
        continue
      }
      if merged[normalizedID] == nil {
        merged[normalizedID] = stampedAt
      }
    }
    return merged
  }

  /// Pre-#214 straggler fold used when the main migration path is
  /// skipped (schema already >= 1) but `archivedWorktreeIDs` still
  /// has entries. Folds into `archivedWorktreeDates` in UserDefaults
  /// — the live `@Shared(.sidebar)` reader's archived-worktree
  /// pruner will pick these up on the next refresh. Clears the ID
  /// list only after the dictionary write lands.
  @MainActor
  private static func foldLegacyArchivedIDsIntoDictionaryStorage(
    legacyArchivedIDs: Shared<[String]>,
    legacyArchived: Shared<[String: Date]>
  ) {
    let ids = legacyArchivedIDs.wrappedValue
    guard !ids.isEmpty else {
      return
    }
    @Dependency(\.date.now) var now
    legacyArchived.withLock { dict in
      for rawID in ids {
        guard let normalizedID = RepositoryPathNormalizer.normalize(rawID) else {
          continue
        }
        if dict[normalizedID] == nil {
          dict[normalizedID] = now
        }
      }
    }
    legacyArchivedIDs.withLock { $0 = [] }
    logger.info("Folded \(ids.count) pre-#214 archived worktree ID(s) into archivedWorktreeDates.")
  }

  /// Seeds ordered sections. `repositoryRoots` is the canonical
  /// baseline — every known root gets an empty section in settings
  /// order — THEN `legacyOrder` is applied as a move-to-top
  /// override so repos the user explicitly reordered win. Mirrors
  /// the live `orderedRepositoryRoots()` behaviour so users who
  /// never dragged a row still see repos in settings order instead
  /// of filesystem-discovery order, and repos with only a main
  /// worktree (no curated row order, never dragged) don't vanish.
  ///
  /// After the baseline + override pass, folds per-repo unpinned
  /// worktree order into `.pinned` / `.unpinned` buckets; entries
  /// that also appear in `legacyPinnedSet` route to `.pinned`.
  private static func seedSections(
    into state: inout SidebarState,
    legacyRoots: [String],
    legacyOrder: [String],
    legacyWorktreeOrder: [String: [String]],
    legacyPinnedSet: Set<Worktree.ID>
  ) {
    // Canonical baseline: every known root, in settings order.
    for root in legacyRoots where state.sections[root] == nil {
      state.sections[root] = .init()
    }
    // Override layer: `legacyOrder` wins — pull matching roots to
    // the top in the order the user curated. Roots present in
    // `legacyOrder` but missing from `repositoryRoots` are still
    // materialised so curated state survives a stale settings file.
    var reordered: OrderedDictionary<Repository.ID, SidebarState.Section> = [:]
    var seen: Set<Repository.ID> = []
    for raw in legacyOrder {
      guard let id = RepositoryPathNormalizer.normalize(raw) else {
        continue
      }
      guard seen.insert(id).inserted else {
        continue
      }
      reordered[id] = state.sections[id] ?? .init()
    }
    for (id, section) in state.sections where !seen.contains(id) {
      reordered[id] = section
    }
    state.sections = reordered

    for (rawRepoID, worktreeIDs) in legacyWorktreeOrder {
      guard let repoID = RepositoryPathNormalizer.normalize(rawRepoID) else {
        continue
      }
      for rawWorktreeID in worktreeIDs {
        guard let worktreeID = RepositoryPathNormalizer.normalize(rawWorktreeID) else {
          continue
        }
        let bucketID: SidebarState.BucketID =
          legacyPinnedSet.contains(worktreeID) ? .pinned : .unpinned
        state.insert(worktree: worktreeID, in: repoID, bucket: bucketID)
      }
    }
  }

  /// Rescues pinned worktrees that didn't appear in the row-order
  /// map (their repo had no curated order). Prefix-matches the path
  /// against the precomputed `rootCandidates` pool (repo root plus
  /// every worktree-base location the convention resolver emitted)
  /// to find the owning repo. Unplaceable entries log the specific
  /// IDs at info level so operators can grep logs.
  private static func rescueOrphanPinned(
    into state: inout SidebarState,
    legacyPinnedSet: Set<Worktree.ID>,
    rootCandidates: [(candidate: String, owningRoot: String)]
  ) {
    var placedPinned: Set<Worktree.ID> = []
    for section in state.sections.values {
      if let pinned = section.buckets[.pinned]?.items.keys {
        placedPinned.formUnion(pinned)
      }
    }
    var unplacedPinnedIDs: [Worktree.ID] = []
    for pinnedID in legacyPinnedSet where !placedPinned.contains(pinnedID) {
      if let repoID = repositoryID(owningWorktreeID: pinnedID, amongLegacyRoots: rootCandidates) {
        state.insert(worktree: pinnedID, in: repoID, bucket: .pinned)
      } else {
        unplacedPinnedIDs.append(pinnedID)
      }
    }
    guard !unplacedPinnedIDs.isEmpty else {
      return
    }
    logger.info(
      "Dropped \(unplacedPinnedIDs.count) orphan pinned worktree(s) with no matching root."
    )
    for id in unplacedPinnedIDs {
      logger.info("Dropped orphan pinned worktree: \(id).")
    }
  }

  /// Applies the collapsed bit. May introduce a new section entry
  /// if the repo was collapsed but had no curated order.
  private static func applyCollapsedFlags(
    into state: inout SidebarState,
    legacyCollapsed: [String]
  ) {
    for raw in legacyCollapsed {
      guard let id = RepositoryPathNormalizer.normalize(raw) else {
        continue
      }
      var section = state.sections[id] ?? .init()
      section.collapsed = true
      state.sections[id] = section
    }
  }

  /// Folds archived timestamps. First tries a section that already
  /// references the worktree; falls back to a prefix match across
  /// the precomputed `rootCandidates` pool when the strict section
  /// lookup fails. Unplaceable entries log the specific IDs at info
  /// level so operators can grep logs.
  private static func foldArchived(
    into state: inout SidebarState,
    legacyArchived: [String: Date],
    rootCandidates: [(candidate: String, owningRoot: String)]
  ) {
    var unplacedArchivedIDs: [Worktree.ID] = []
    for (rawArchivedID, archivedAt) in legacyArchived {
      guard let archivedWorktreeID = RepositoryPathNormalizer.normalize(rawArchivedID) else {
        continue
      }
      let owningRepoID =
        state.sections.first(where: { _, section in
          section.buckets.values.contains(where: { $0.items[archivedWorktreeID] != nil })
        })?.key
        ?? repositoryID(owningWorktreeID: archivedWorktreeID, amongLegacyRoots: rootCandidates)
      guard let owningRepoID else {
        unplacedArchivedIDs.append(archivedWorktreeID)
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
    guard !unplacedArchivedIDs.isEmpty else {
      return
    }
    logger.info(
      "Dropped \(unplacedArchivedIDs.count) orphan archived worktree(s) with no matching root."
    )
    for id in unplacedArchivedIDs {
      logger.info("Dropped orphan archived worktree: \(id).")
    }
  }

  /// Atomic write of the new nested shape. `storage.save` writes
  /// via temp+rename, so the file either exists completely or
  /// not at all. Bypass the `@Shared(.sidebar)` cache so the
  /// SharedKey doesn't hydrate with an empty `SidebarState()`
  /// before the real contents land on disk. Returns `false` and
  /// logs on failure so the caller can bail before touching the
  /// legacy sources.
  private static func persist(state: SidebarState, to sidebarURL: URL) -> Bool {
    do {
      @Dependency(\.settingsFileStorage) var storage
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(state)
      try storage.save(data, sidebarURL)
      return true
    } catch {
      logger.warning("Failed to write sidebar.json during migration: \(error)")
      return false
    }
  }

  /// Pool of (candidate-prefix → owning-root) pairs used by the
  /// longest-prefix resolver. Covers every filesystem location a
  /// worktree may sit under:
  /// - The repo root itself (worktrees nested directly inside the
  ///   checkout).
  /// - The effective worktree-base directory derived from
  ///   `SupacodePaths.worktreeBaseDirectory(for:globalDefaultPath:
  ///   repositoryOverridePath:)`, which routes through (in priority
  ///   order) per-repo `supacode.json` override → global
  ///   `defaultWorktreeBaseDirectoryPath` override → default
  ///   `~/.supacode/repos/<lastPathComponent>/` convention.
  /// Per-repo overrides are read synchronously from disk via the
  /// `\.repositoryLocalSettingsStorage` dependency — NOT
  /// `@Shared(.repositorySettings(rootURL))`, whose async
  /// hydration path would race the one-shot migrator. Missing /
  /// corrupt `supacode.json` files are skipped silently; the
  /// default-convention candidate always emits so the convention
  /// fallback still works.
  private static func rootCandidates(
    legacyRoots: [String],
    settingsFile: SettingsFile
  ) -> [(candidate: String, owningRoot: String)] {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let globalDefaultPath = settingsFile.global.defaultWorktreeBaseDirectoryPath
    var candidates: [(candidate: String, owningRoot: String)] = []
    var seen: Set<String> = []
    for owningRoot in legacyRoots {
      let rootURL = URL(fileURLWithPath: owningRoot)
      // 1. Root itself — worktrees living directly under the
      //    checkout (custom worktree dirs that are relative paths
      //    resolving inside the root).
      if let normalisedRoot = RepositoryPathNormalizer.normalize(owningRoot),
        seen.insert(normalisedRoot).inserted
      {
        candidates.append((candidate: normalisedRoot, owningRoot: owningRoot))
      }
      // 2. Per-repo override, read synchronously (no SharedKey).
      let perRepoOverride = loadRepositoryOverridePath(
        for: rootURL,
        storage: repositoryLocalSettingsStorage
      )
      // 3. Effective worktree-base for this root, applying all
      //    three layers of precedence. Emits the default
      //    `~/.supacode/repos/<name>/` convention when no override
      //    is configured.
      let worktreeBase = SupacodePaths.worktreeBaseDirectory(
        for: rootURL,
        globalDefaultPath: globalDefaultPath,
        repositoryOverridePath: perRepoOverride
      )
      let worktreeBasePath = worktreeBase.path(percentEncoded: false)
      if let normalisedBase = RepositoryPathNormalizer.normalize(worktreeBasePath),
        seen.insert(normalisedBase).inserted
      {
        candidates.append((candidate: normalisedBase, owningRoot: owningRoot))
      }
    }
    return candidates
  }

  /// Synchronously reads `<root>/supacode.json` via the injected
  /// storage dependency and returns the persisted
  /// `worktreeBaseDirectoryPath` override, or `nil` when the file
  /// is missing, unreadable, decode-fails, or doesn't set an
  /// override. Must not hit `@Shared(.repositorySettings(rootURL))`
  /// — that SharedKey hydrates asynchronously and would race the
  /// one-shot migrator.
  private static func loadRepositoryOverridePath(
    for rootURL: URL,
    storage: RepositoryLocalSettingsStorage
  ) -> String? {
    let url = SupacodePaths.repositorySettingsURL(for: rootURL)
    guard let data = try? storage.load(url) else {
      return nil
    }
    guard let settings = try? JSONDecoder().decode(RepositorySettings.self, from: data) else {
      return nil
    }
    return settings.worktreeBaseDirectoryPath
  }

  /// Recover the owning `Repository.ID` for a legacy flat worktree
  /// ID (a filesystem path) by prefix-matching against the
  /// precomputed candidate pool. Each entry pairs a candidate
  /// prefix (repo root OR a worktree-base directory) with the
  /// `Repository.ID` that owns it, so a pin sitting under
  /// `~/.supacode/repos/<name>/` still resolves to the settings
  /// root under `~/Developer/.../` even when the two trees share
  /// no common ancestor. Returns the longest-matching candidate's
  /// `owningRoot` so nested roots and nested bases win. Expects
  /// `worktreeID` and every `candidate` to already be normalised
  /// via `RepositoryPathNormalizer.normalize`.
  static func repositoryID(
    owningWorktreeID worktreeID: Worktree.ID,
    amongLegacyRoots candidates: [(candidate: String, owningRoot: String)]
  ) -> Repository.ID? {
    var bestMatch: (owningRoot: String, length: Int)?
    for (candidate, owningRoot) in candidates {
      // Strip trailing slashes before appending the directory
      // separator below — otherwise "/repo-a/" concatenates to
      // "/repo-a//" and matches nothing.
      let trimmedCandidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !trimmedCandidate.isEmpty else {
        continue
      }
      let candidateWithLeadingSlash = "/" + trimmedCandidate
      // The worktree path should sit under the candidate's
      // directory; the trailing slash guards against a spurious
      // match where one candidate is a non-directory prefix of
      // another (e.g. "/tmp/rep" vs "/tmp/repo").
      guard worktreeID.hasPrefix(candidateWithLeadingSlash + "/") else {
        continue
      }
      if candidateWithLeadingSlash.count > (bestMatch?.length ?? 0) {
        bestMatch = (owningRoot, candidateWithLeadingSlash.count)
      }
    }
    return bestMatch?.owningRoot
  }
}
