import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

/// Injectable file-system seam for the relocation, so tests never touch the real
/// `~/.supacode`. Only the raw path operations live here; the settings writes go
/// through `\.settingsFileStorage` and the UserDefaults writes through
/// `\.defaultAppStorage`, both already test-injectable.
struct RelocationFileSystem: Sendable {
  var fileExists: @Sendable (URL) -> Bool
  var readData: @Sendable (URL) -> Data?
  var writeData: @Sendable (Data, URL) throws -> Void
  var isSymbolicLink: @Sendable (URL) -> Bool
  var moveItem: @Sendable (URL, URL) throws -> Void
  var createDirectory: @Sendable (URL) throws -> Void
  var contentsOfDirectory: @Sendable (URL) -> [URL]

  static let live = RelocationFileSystem(
    fileExists: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
    readData: { url in try? Data(contentsOf: url) },
    writeData: { data, url in try SymlinkPreservingFileWriter.write(data, to: url) },
    isSymbolicLink: { url in
      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    },
    moveItem: { source, destination in
      try FileManager.default.moveItem(at: source, to: destination)
    },
    createDirectory: { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    },
    contentsOfDirectory: { url in
      (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }
  )
}

/// What `run` did this launch. `.pending` carries human-readable problems for the
/// launch-time alert; the underlying data is always preserved in place.
enum RelocationOutcome: Equatable, Sendable {
  case noLegacyData
  case completed
  case pending(problems: [String])
}

/// One-shot relocation of Supacode config out of `~/.supacode` and into
/// `~/.config/supacode`, plus sidebar / layouts into UserDefaults. The old
/// single `settings.json` splits into `config.json` (global) + `routes.json`
/// (roots) + `repos.json` (per-repo settings); `ghostty.config` becomes
/// `config.ghostty`. Legacy files move into `~/.supacode/.backup`, leaving only
/// `repos` behind.
///
/// Every step is independent and non-throwing: one failing file never aborts the
/// rest, and a legacy file is retired into `.backup` only once its new-store
/// counterpart is fully written, so a partial run never loses data. The seed +
/// legacy migrators run only until the durable `.relocated` marker exists, and
/// the retire step runs only after it, so the migrators never run against a
/// half-moved tree. A crash resumes on the next launch.
@MainActor
enum SettingsRelocationMigrator {
  private static let logger = SupaLogger("Settings")

  /// Runs the whole relocation and reports the outcome. Never throws.
  /// `legacyMigrators` is injectable so tests exercise the relocation without the
  /// real-disk schema migrators.
  static func run(
    fileSystem: RelocationFileSystem = .live,
    legacyMigrators: @MainActor () -> Void = Self.runLegacySchemaMigrators
  ) -> RelocationOutcome {
    guard hasLegacyFiles(fileSystem: fileSystem) else { return .noLegacyData }
    var problems: [String] = []
    if !isRelocated(fileSystem: fileSystem) {
      // Run the legacy schema migrators FIRST. They read `@Shared(.settingsFile)`,
      // which falls back to the legacy `settings.json` while the split store is
      // empty, so they see the real data INCLUDING `pinnedWorktreeIDs` (which the
      // split store drops) and fold the pins into `sidebar.json` before the seed
      // writes a pin-less store.
      legacyMigrators()
      // Seed the split settings store from the legacy file (a no-op if the
      // migrators' own save already wrote it).
      problems += seedSettingsFromLegacy(fileSystem: fileSystem)
      // Seed the UserDefaults stores from the final legacy files, then stamp the
      // marker so the retire step can run and the migrators never re-run.
      problems += finishSeeding(fileSystem: fileSystem)
    }
    // Retire legacy files (each only once its counterpart is populated). Resumes
    // a partial prior run; move failures leave the source in place, so they are
    // logged, not surfaced.
    retireLegacyFiles(fileSystem: fileSystem)
    return problems.isEmpty ? .completed : .pending(problems: problems)
  }

  /// True when any legacy `~/.supacode` config file still exists, so relocation
  /// has work to do this launch.
  static func hasLegacyFiles(fileSystem: RelocationFileSystem = .live) -> Bool {
    Self.legacyFiles.contains(where: fileSystem.fileExists)
  }

  /// True once the durable relocation marker exists (every new store seeded).
  static func isRelocated(fileSystem: RelocationFileSystem = .live) -> Bool {
    fileSystem.fileExists(SupacodePaths.relocationMarkerURL)
  }

  // MARK: - Phases

  /// Existing schema migrators, run on the legacy files while they are all still
  /// present. Void, idempotent, schemaVersion-gated.
  private static func runLegacySchemaMigrators() {
    // Snapshot settings.json + sidebar.json before any migration or @Shared
    // hydration can rewrite them, so a botched migration is recoverable by hand.
    SidebarPersistenceMigrator.backupBeforeRemoteIdentityMigration()
    // Capture the retired `global.remoteRepositories` before any migration can
    // re-encode settings and drop the field.
    let capturedLegacyRemotes = SidebarPersistenceMigrator.captureLegacyRemoteRoots()
    if capturedLegacyRemotes != .unreadable {
      SidebarPersistenceMigrator.migrateIfNeeded()
      SidebarPersistenceMigrator.migrateRemoteIdentityIfNeeded(capturedLegacy: capturedLegacyRemotes)
      SidebarPersistenceMigrator.migrateRemoteSlashIDsIfNeeded()
    }
    // Rewrite v1 layouts.json into the v2 pane topology before it seeds UserDefaults.
    LayoutsMigrator.migrateFileIfNeeded()
  }

  /// Seeds `config.json` / `routes.json` / `repos.json` from the legacy
  /// `settings.json`. No-op once the new store exists or no legacy file.
  static func seedSettingsFromLegacy(fileSystem: RelocationFileSystem = .live) -> [String] {
    // Re-seed while any settings slice is missing, so a resumed run rewrites a
    // partially-written store (config alone existing must not block routes /
    // repositories). Checked through `settingsFileStorage`, which writes them.
    guard !settingsStoreComplete() else { return [] }
    guard let data = fileSystem.readData(SupacodePaths.legacySettingsURL) else { return [] }
    guard let legacy = try? JSONDecoder().decode(SettingsFile.self, from: data) else {
      logger.error("Legacy settings.json present but undecodable; leaving it in place, not seeding.")
      return ["Your existing settings.json could not be read, so it was left untouched."]
    }
    return writeSettingsStore(legacy)
  }

  /// Seeds the UserDefaults stores from the final legacy files, relocates the
  /// Ghostty config, then stamps the durable marker.
  static func finishSeeding(fileSystem: RelocationFileSystem = .live) -> [String] {
    var problems = seedUserDefaultsStores(fileSystem: fileSystem)
    problems += relocateGhosttyConfig(fileSystem: fileSystem)
    // Only complete when every legacy store has been fully dealt with. A store
    // that still needs work (a transient read failure, or a Ghostty config that
    // exists but hasn't reached `config.ghostty`) withholds the marker so the move
    // retries next launch. A readable-but-corrupt store is unrecoverable and does
    // not block, so it can't wedge the migration forever.
    @Dependency(\.defaultAppStorage) var defaults
    let pending = pendingStores(fileSystem: fileSystem)
    guard pending.isEmpty else {
      // Surface the retry once, then stay silent: a permanently unreadable file
      // must not nag on every launch (the data is preserved in place regardless).
      guard !defaults.bool(forKey: Self.pendingNotifiedKey) else { return [] }
      defaults.set(true, forKey: Self.pendingNotifiedKey)
      for name in pending {
        problems.append("Your \(name) could not be moved yet; it will retry next launch.")
      }
      return problems
    }
    defaults.removeObject(forKey: Self.pendingNotifiedKey)
    problems += markRelocated(fileSystem: fileSystem)
    return problems
  }

  /// UserDefaults flag: whether the "still moving" notice has already been shown,
  /// so a permanently-stuck store is retried silently instead of nagging.
  private static let pendingNotifiedKey = "settingsRelocationPendingNotified"

  /// Legacy stores that still need work this launch: a UserDefaults store whose
  /// legacy file exists but couldn't be read (a transient I/O failure, distinct
  /// from absence or a readable-but-corrupt file), or a legacy Ghostty config that
  /// exists but hasn't been copied to `config.ghostty` (a read OR write failure).
  private static func pendingStores(fileSystem: RelocationFileSystem) -> [String] {
    @Dependency(\.defaultAppStorage) var defaults
    var names: [String] = []
    if !userDefaultsHoldsValid(SidebarState.self, forKey: SidebarKey.storageKey, defaults),
      presentButUnreadable(SupacodePaths.legacySidebarURL, fileSystem)
    {
      names.append("sidebar layout")
    }
    if !userDefaultsHoldsValid(LayoutsFile.self, forKey: LayoutsFile.userDefaultsKey, defaults),
      presentButUnreadable(SupacodePaths.legacyLayoutsURL, fileSystem)
    {
      names.append("terminal layouts")
    }
    if fileSystem.fileExists(SupacodePaths.legacyGhosttyUserConfigURL),
      !fileSystem.fileExists(SupacodePaths.ghosttyUserConfigURL)
    {
      names.append("Ghostty config")
    }
    return names
  }

  private static func presentButUnreadable(_ url: URL, _ fileSystem: RelocationFileSystem) -> Bool {
    fileSystem.fileExists(url) && fileSystem.readData(url) == nil
  }

  /// Retires the file-backed legacy files (settings, Ghostty) into `.backup` once
  /// their new-store counterpart exists, and sweeps stray `.bak` / `.corrupt-*`
  /// files. Sidebar / layouts are retired inside the seed instead, because their
  /// UserDefaults key can't distinguish seeded data from what the app later wrote.
  /// Safe to run every launch: settings.json needs all three new files, and both
  /// counterparts are only ever produced by the seed (never the app's own writes).
  static func retireLegacyFiles(fileSystem: RelocationFileSystem = .live) {
    let retirable: [(url: URL, landed: Bool)] = [
      (SupacodePaths.legacySettingsURL, settingsStoreComplete()),
      (SupacodePaths.legacyGhosttyUserConfigURL, fileSystem.fileExists(SupacodePaths.ghosttyUserConfigURL)),
    ]
    for entry in retirable where entry.landed {
      moveToBackup(entry.url, fileSystem: fileSystem)
    }
    sweepLooseBackups(fileSystem: fileSystem)
  }

  // MARK: - Steps

  /// Writes each new file independently so one failure never skips the others.
  private static func writeSettingsStore(_ settings: SettingsFile) -> [String] {
    let encoder = Self.makeEncoder()
    var problems: [String] = []
    write({ try encoder.encode(settings.global) }, to: SupacodePaths.configURL, "global settings", &problems)
    let routes = RoutesFile(local: settings.repositoryRoots, remote: settings.remoteRepositoryRoots)
    write({ try encoder.encode(routes) }, to: SupacodePaths.routesURL, "repository list", &problems)
    write({ try encoder.encode(settings.repositories) }, to: SupacodePaths.reposURL, "repository settings", &problems)
    return problems
  }

  private static func write(
    _ encode: () throws -> Data,
    to url: URL,
    _ label: String,
    _ problems: inout [String]
  ) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      try storage.save(try encode(), url)
    } catch {
      logger.error("Failed to write \(url.lastPathComponent): \(error)")
      problems.append("Your \(label) could not be written to \(url.lastPathComponent).")
    }
  }

  private static func seedUserDefaultsStores(fileSystem: RelocationFileSystem) -> [String] {
    @Dependency(\.defaultAppStorage) var defaults
    let encoder = Self.makeEncoder()
    var problems: [String] = []
    // Sidebar: copy the final legacy `sidebar.json` (schemaVersion preserved) into
    // UserDefaults. Seed when the key holds no VALID value (absent or corrupt); a
    // value that decodes is the app's own state and is kept.
    if !userDefaultsHoldsValid(SidebarState.self, forKey: SidebarKey.storageKey, defaults),
      let data = fileSystem.readData(SupacodePaths.legacySidebarURL)
    {
      if let sidebar = try? JSONDecoder().decode(SidebarState.self, from: data),
        let encoded = try? encoder.encode(sidebar)
      {
        // Preserve an existing-but-invalid value, then seed and retire the legacy
        // file in the same run (a later launch can't tell a seeded key from one the
        // app wrote, so it must not drive retirement).
        stashCorruptUserDefaults(forKey: SidebarKey.storageKey, defaults)
        defaults.set(encoded, forKey: SidebarKey.storageKey)
        // Flush before retiring the source: UserDefaults writes are deferred, and
        // a crash before the flush would otherwise lose the only live copy.
        defaults.synchronize()
        moveToBackup(SupacodePaths.legacySidebarURL, fileSystem: fileSystem)
      } else {
        logger.error("Legacy sidebar.json present but undecodable; leaving it in place, not seeding.")
        problems.append("Your sidebar layout could not be read, so it was left untouched.")
      }
    }
    // Layouts: normalize the final legacy `layouts.json` (v2) into UserDefaults,
    // seeding only when the key holds no valid value.
    if !userDefaultsHoldsValid(LayoutsFile.self, forKey: LayoutsFile.userDefaultsKey, defaults),
      fileSystem.readData(SupacodePaths.legacyLayoutsURL) != nil
    {
      if case .file(let file) = LayoutsFile.readFromDisk(url: SupacodePaths.legacyLayoutsURL),
        let encoded = try? encoder.encode(file)
      {
        stashCorruptUserDefaults(forKey: LayoutsFile.userDefaultsKey, defaults)
        defaults.set(encoded, forKey: LayoutsFile.userDefaultsKey)
        // Flush before retiring the source (UserDefaults writes are deferred).
        defaults.synchronize()
        moveToBackup(SupacodePaths.legacyLayoutsURL, fileSystem: fileSystem)
      } else {
        logger.error("Legacy layouts.json present but unreadable; leaving it in place, not seeding.")
        problems.append("Your terminal layouts could not be read, so they were left untouched.")
      }
    }
    return problems
  }

  private static func relocateGhosttyConfig(fileSystem: RelocationFileSystem) -> [String] {
    // `ghosttyUserConfigURL` now points at the new `config.ghostty`.
    let destination = SupacodePaths.ghosttyUserConfigURL
    guard !fileSystem.fileExists(destination) else { return [] }
    guard let data = fileSystem.readData(SupacodePaths.legacyGhosttyUserConfigURL) else {
      if fileSystem.fileExists(SupacodePaths.legacyGhosttyUserConfigURL) {
        logger.error("Legacy ghostty.config present but unreadable; leaving it in place, will retry.")
      }
      return []
    }
    do {
      try fileSystem.writeData(data, destination)
      return []
    } catch {
      logger.error("Failed to relocate Ghostty config: \(error)")
      return ["Your Ghostty config could not be moved to config.ghostty."]
    }
  }

  private static func markRelocated(fileSystem: RelocationFileSystem) -> [String] {
    guard !fileSystem.fileExists(SupacodePaths.relocationMarkerURL) else { return [] }
    // Only complete once the settings store is fully seeded, so a failed settings
    // write retries next launch instead of locking in a partial relocation. A
    // corrupt sidebar / layouts (safely preserved in place) does not block it.
    guard settingsStoreComplete() else { return [] }
    do {
      try fileSystem.writeData(Data(), SupacodePaths.relocationMarkerURL)
      return []
    } catch {
      logger.error("Failed to write relocation marker: \(error)")
      return ["The migration could not be marked complete, so it will retry on next launch."]
    }
  }

  /// Moves a legacy file into `.backup`. A symlink is left in place: relocating
  /// the link would dangle the user's dotfiles tree, and its content already
  /// lives at the new path.
  private static func moveToBackup(_ url: URL, fileSystem: RelocationFileSystem) {
    guard fileSystem.fileExists(url), !fileSystem.isSymbolicLink(url) else { return }
    move(url, into: SupacodePaths.backupDirectory, fileSystem: fileSystem)
  }

  /// Sweeps pre-existing `.bak` / `.corrupt-*` files loose in `~/.supacode` into
  /// `.backup`, so only `repos` and `.backup` remain there.
  private static func sweepLooseBackups(fileSystem: RelocationFileSystem) {
    for entry in fileSystem.contentsOfDirectory(SupacodePaths.baseDirectory) {
      let name = entry.lastPathComponent
      guard name.hasSuffix(".bak") || name.contains(".corrupt-") else { continue }
      move(entry, into: SupacodePaths.backupDirectory, fileSystem: fileSystem)
    }
  }

  /// Moves `url` into `directory`, creating it first and never overwriting an
  /// existing snapshot (the golden pre-relocation copy stays put).
  private static func move(_ url: URL, into directory: URL, fileSystem: RelocationFileSystem) {
    let destination = directory.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
    guard !fileSystem.fileExists(destination) else { return }
    do {
      try fileSystem.createDirectory(directory)
      try fileSystem.moveItem(url, destination)
    } catch {
      logger.warning("Failed to move \(url.lastPathComponent) into .backup: \(error)")
    }
  }

  // MARK: - Helpers

  private static var legacyFiles: [URL] {
    [
      SupacodePaths.legacySettingsURL,
      SupacodePaths.legacySidebarURL,
      SupacodePaths.legacyLayoutsURL,
      SupacodePaths.legacyGhosttyUserConfigURL,
    ]
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  /// Whether all three split settings files exist AND decode to their expected
  /// type. Completion means the data is actually recoverable, not just present:
  /// a corrupt slice must keep the relocation pending (re-seeding from the legacy
  /// file) and must not let the legacy source be retired.
  private static func settingsStoreComplete() -> Bool {
    settingsFileDecodes(SupacodePaths.configURL, as: GlobalSettings.self)
      && settingsFileDecodes(SupacodePaths.routesURL, as: RoutesFile.self)
      && settingsFileDecodes(SupacodePaths.reposURL, as: [String: RepositorySettings].self)
  }

  private static func settingsFileDecodes<T: Decodable>(_ url: URL, as _: T.Type) -> Bool {
    @Dependency(\.settingsFileStorage) var storage
    guard let data = try? storage.load(url) else { return false }
    return (try? JSONDecoder().decode(T.self, from: data)) != nil
  }

  /// Whether a UserDefaults key holds a value that decodes to `T`. A present but
  /// undecodable value is not "seeded": it must be re-seeded from the legacy file.
  private static func userDefaultsHoldsValid<T: Decodable>(
    _: T.Type,
    forKey key: String,
    _ defaults: UserDefaults
  ) -> Bool {
    guard let data = defaults.data(forKey: key) else { return false }
    return (try? JSONDecoder().decode(T.self, from: data)) != nil
  }

  /// Preserves an existing-but-invalid UserDefaults value under a sibling recovery
  /// key before the seed overwrites it.
  private static func stashCorruptUserDefaults(forKey key: String, _ defaults: UserDefaults) {
    guard let data = defaults.data(forKey: key) else { return }
    defaults.set(data, forKey: key + ".corrupt")
  }
}
