import Dependencies
import Foundation
import Sharing

public nonisolated struct SettingsFileStorage: Sendable {
  public var load: @Sendable (URL) throws -> Data
  public var save: @Sendable (Data, URL) throws -> Void

  public init(
    load: @escaping @Sendable (URL) throws -> Data,
    save: @escaping @Sendable (Data, URL) throws -> Void
  ) {
    self.load = load
    self.save = save
  }
}

public nonisolated enum SettingsFileStorageKey: DependencyKey {
  public static var liveValue: SettingsFileStorage {
    SettingsFileStorage(
      load: { try Data(contentsOf: $0) },
      save: { data, url in try SymlinkPreservingFileWriter.write(data, to: url) }
    )
  }
  public static var previewValue: SettingsFileStorage { .inMemory() }
  public static var testValue: SettingsFileStorage { .inMemory() }
}

/// The three files the in-memory `SettingsFile` decomposes into: `config.json`
/// (raw `GlobalSettings`), `routes.json` (local / remote roots) and
/// `repos.json` (per-repo settings fallback).
public nonisolated struct SettingsFileURLs: Sendable, Hashable {
  public let config: URL
  public let routes: URL
  public let repositories: URL

  // Not public: the collision-free invariant is only guaranteed by `derivedFrom`
  // and `.live`, so external callers construct through those.
  init(config: URL, routes: URL, repositories: URL) {
    self.config = config
    self.routes = routes
    self.repositories = repositories
  }

  /// Derives `routes` / `repositories` as siblings of a single settings URL, so
  /// a caller (or test) that only knows one path still gets a unique, collision-free
  /// trio: `foo.json` → `foo.routes.json` / `foo.repos.json`.
  public init(derivedFrom settingsURL: URL) {
    let ext = settingsURL.pathExtension.isEmpty ? "json" : settingsURL.pathExtension
    let base = settingsURL.deletingPathExtension()
    config = settingsURL
    routes = base.appendingPathExtension("routes").appendingPathExtension(ext)
    repositories = base.appendingPathExtension("repos").appendingPathExtension(ext)
  }

  public static var live: SettingsFileURLs {
    SettingsFileURLs(
      config: SupacodePaths.configURL,
      routes: SupacodePaths.routesURL,
      repositories: SupacodePaths.reposURL
    )
  }
}

public nonisolated enum SettingsFileURLsKey: DependencyKey {
  public static var liveValue: SettingsFileURLs { .live }
  public static var previewValue: SettingsFileURLs { .live }
  public static var testValue: SettingsFileURLs {
    SettingsFileURLs(
      derivedFrom: FileManager.default.temporaryDirectory
        .appending(path: "supacode-settings-\(UUID().uuidString).json", directoryHint: .notDirectory)
    )
  }
}

extension DependencyValues {
  public nonisolated var settingsFileStorage: SettingsFileStorage {
    get { self[SettingsFileStorageKey.self] }
    set { self[SettingsFileStorageKey.self] = newValue }
  }

  public nonisolated var settingsFileURLs: SettingsFileURLs {
    get { self[SettingsFileURLsKey.self] }
    set { self[SettingsFileURLsKey.self] = newValue }
  }

  /// Back-compat handle: reading yields `config`; assigning derives the whole
  /// trio from that single path. Lets callers that predate the split keep
  /// pointing the settings store at one URL.
  public nonisolated var settingsFileURL: URL {
    get { settingsFileURLs.config }
    set { settingsFileURLs = SettingsFileURLs(derivedFrom: newValue) }
  }

  public nonisolated var settingsStoreHealth: SettingsStoreHealth {
    get { self[SettingsStoreHealthKey.self] }
    set { self[SettingsStoreHealthKey.self] = newValue }
  }
}

/// Tracks settings stores that loaded degraded (a slice was present but
/// unreadable), so saves refuse to overwrite the real-but-unreadable files with
/// default-derived values until a clean reload clears the flag. Injected so tests
/// stay isolated from each other and from the live singleton.
public nonisolated final class SettingsStoreHealth: @unchecked Sendable {
  private let lock = NSLock()
  /// Keyed by the store's canonical `config` path, normalized so incidental URL
  /// spelling can't make a flag set in `load` invisible to `save`.
  private var degraded: Set<URL> = []

  public init() {}

  public func markDegraded(_ urls: SettingsFileURLs) {
    lock.withLock { _ = degraded.insert(Self.key(urls)) }
  }

  public func markHealthy(_ urls: SettingsFileURLs) {
    lock.withLock { degraded.remove(Self.key(urls)) }
  }

  public func isDegraded(_ urls: SettingsFileURLs) -> Bool {
    lock.withLock { degraded.contains(Self.key(urls)) }
  }

  private static func key(_ urls: SettingsFileURLs) -> URL {
    urls.config.standardizedFileURL
  }
}

public nonisolated enum SettingsStoreHealthKey: DependencyKey {
  public static let liveValue = SettingsStoreHealth()
  public static var previewValue: SettingsStoreHealth { SettingsStoreHealth() }
  public static var testValue: SettingsStoreHealth { SettingsStoreHealth() }
}

public nonisolated enum SettingsStoreError: Error, Equatable {
  /// The store loaded degraded, so a save was refused to avoid overwriting real
  /// data with defaults.
  case degraded
}

extension SettingsFileStorage {
  public nonisolated static func inMemory() -> SettingsFileStorage {
    let storage = InMemorySettingsFileStorage()
    return SettingsFileStorage(
      load: { try storage.load($0) },
      save: { try storage.save($0, $1) }
    )
  }
}

nonisolated final class InMemorySettingsFileStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      // Mirror real-disk semantics so callers that distinguish "file absent"
      // (fresh start) from a read failure see the same `fileReadNoSuchFile`.
      throw CocoaError(.fileReadNoSuchFile)
    }
    return data
  }

  func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }

}

/// `routes.json`: the added repository roots, split into local paths and remote
/// ids. Mirrors `SettingsFile.repositoryRoots` / `.remoteRepositoryRoots`.
public nonisolated struct RoutesFile: Codable, Equatable, Sendable {
  public var local: [String]
  public var remote: [String]

  public init(local: [String] = [], remote: [String] = []) {
    self.local = local
    self.remote = remote
  }

  enum CodingKeys: String, CodingKey {
    case local
    case remote
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    local = try container.decodeIfPresent([String].self, forKey: .local) ?? []
    remote = try container.decodeIfPresent([String].self, forKey: .remote) ?? []
  }
}

public nonisolated struct SettingsFileKey: SharedKey {
  private static let logger = SupaLogger("Settings")

  public let urls: SettingsFileURLs

  public init(urls: SettingsFileURLs? = nil) {
    if let urls {
      self.urls = urls
      return
    }
    @Dependency(\.settingsFileURLs) var settingsFileURLs
    self.urls = settingsFileURLs
  }

  public var id: SettingsFileURLs {
    urls
  }

  public func load(context: LoadContext<SettingsFile>, continuation: LoadContinuation<SettingsFile>) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.settingsStoreHealth) var health
    let decoder = JSONDecoder()
    // The value served when we can't hydrate real data from disk.
    let initialValue = context.initialValue ?? .default
    let configRead = Self.read(urls.config, storage)
    let routesRead = Self.read(urls.routes, storage)
    let repositoriesRead = Self.read(urls.repositories, storage)

    // A transient read failure (not genuine absence) must never hydrate defaults
    // over the real file: serve the initial value without persisting anything, and
    // mark the store degraded so a later mutation can't save defaults over it. The
    // real files survive and the next launch retries.
    if configRead.isUnreadable || routesRead.isUnreadable || repositoriesRead.isUnreadable {
      Self.logger.error("A settings file is present but unreadable; serving the initial value, not persisting.")
      health.markDegraded(urls)
      continuation.resume(returning: initialValue)
      return
    }

    let configData = configRead.data
    let routesData = routesRead.data
    let repositoriesData = repositoriesRead.data

    // Empty new store. A legacy settings.json here means the relocation is
    // pending or failed: read it WITHOUT writing defaults, so a failed migration
    // never masks the real data with defaults (which would also let the retire
    // step treat those defaults as a landed migration and retire the real file).
    // Only a genuinely fresh install (no legacy file either) seeds defaults.
    if configData == nil, routesData == nil, repositoriesData == nil {
      switch Self.read(SupacodePaths.legacySettingsURL, storage) {
      case .data(let legacyData):
        if let legacy = try? decoder.decode(SettingsFile.self, from: legacyData) {
          health.markHealthy(urls)
          continuation.resume(returning: legacy)
          return
        }
      // A corrupt legacy file is unrecoverable: fall through to a fresh default store.
      case .unreadable:
        // Transient: don't seed defaults over the (real) legacy file; retry next launch.
        health.markDegraded(urls)
        continuation.resume(returning: initialValue)
        return
      case .absent:
        break
      }
      health.markHealthy(urls)
      _ = try? save(initialValue, storage: storage)
      continuation.resumeReturningInitialValue()
      return
    }

    // Partial split store (an interrupted relocation left only some slices). The
    // legacy settings.json is the complete real data: serve it and mark degraded,
    // so a mutation can't complete the partial store with defaults and let the next
    // launch retire the legacy file. The relocation re-seeds it next launch.
    if configData == nil || routesData == nil || repositoriesData == nil {
      switch Self.read(SupacodePaths.legacySettingsURL, storage) {
      case .data(let legacyData):
        if let legacy = try? decoder.decode(SettingsFile.self, from: legacyData) {
          health.markDegraded(urls)
          continuation.resume(returning: legacy)
          return
        }
      // Corrupt legacy: no usable real data, fall through to a best-effort compose.
      case .unreadable:
        health.markDegraded(urls)
        continuation.resume(returning: initialValue)
        return
      case .absent:
        break  // No legacy: the missing slices are genuinely gone; compose below.
      }
    }

    // A present-but-corrupt file is rotated aside (preserved) and its slice falls
    // back to a default, so one bad file never discards the other two.
    let global = decodeOrRotate(configData, at: urls.config, as: GlobalSettings.self, decoder) ?? .default
    let routes = decodeOrRotate(routesData, at: urls.routes, as: RoutesFile.self, decoder) ?? RoutesFile()
    let repositories =
      decodeOrRotate(repositoriesData, at: urls.repositories, as: [String: RepositorySettings].self, decoder)
      ?? [:]
    // `pinnedWorktreeIDs` is sidebar curation now (in `SidebarState`), no longer
    // persisted here.
    let settings = SettingsFile(
      global: global,
      repositories: repositories,
      repositoryRoots: routes.local,
      remoteRepositoryRoots: routes.remote,
      pinnedWorktreeIDs: []
    )
    health.markHealthy(urls)
    continuation.resume(returning: settings)
  }

  /// Decodes `data`, or rotates a present-but-corrupt file aside and returns nil
  /// so the caller uses a default. `nil` data (absent) returns nil without a
  /// rotation. Preserves the bytes for recovery instead of silently overwriting.
  private func decodeOrRotate<T: Decodable>(
    _ data: Data?,
    at url: URL,
    as type: T.Type,
    _ decoder: JSONDecoder
  ) -> T? {
    guard let data else { return nil }
    if let value = try? decoder.decode(T.self, from: data) { return value }
    Self.logger.error(
      "\(url.lastPathComponent) present but undecodable; rotating aside and falling back to defaults."
    )
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let destination = url.deletingLastPathComponent()
      .appending(
        path: "\(url.lastPathComponent).corrupt-\(formatter.string(from: Date()).replacing(":", with: "-"))",
        directoryHint: .notDirectory
      )
    do {
      try SymlinkPreservingFileWriter.moveAside(at: url, to: destination)
    } catch {
      Self.logger.error(
        "Failed to rotate corrupt \(url.lastPathComponent) aside: \(error). The next save will overwrite it."
      )
    }
    return nil
  }

  public func subscribe(
    context _: LoadContext<SettingsFile>,
    subscriber _: SharedSubscriber<SettingsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(_ value: SettingsFile, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      try save(value, storage: storage)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

  private func save(_ value: SettingsFile, storage: SettingsFileStorage) throws {
    // Refuse to persist over a store that loaded degraded (a slice was present but
    // unreadable): the in-memory value is default-derived, so writing it would
    // overwrite the real data. Cleared by a clean reload on the next launch.
    @Dependency(\.settingsStoreHealth) var health
    guard !health.isDegraded(urls) else {
      Self.logger.error("Settings save refused: store loaded degraded; changes will not persist until relaunch.")
      throw SettingsStoreError.degraded
    }
    let encoder = Self.makeEncoder()
    try storage.save(try encoder.encode(value.global), urls.config)
    let routes = RoutesFile(local: value.repositoryRoots, remote: value.remoteRepositoryRoots)
    try storage.save(try encoder.encode(routes), urls.routes)
    try storage.save(try encoder.encode(value.repositories), urls.repositories)
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  /// The outcome of reading one settings file, distinguishing genuine absence
  /// from a transient I/O failure so the latter never looks like a fresh install.
  private enum SliceRead {
    case data(Data)
    case absent
    case unreadable

    /// Bytes if present, else nil. Only sound after the caller has handled `.unreadable`.
    var data: Data? {
      if case .data(let data) = self { return data }
      return nil
    }

    var isUnreadable: Bool {
      if case .unreadable = self { return true }
      return false
    }
  }

  private static func read(_ url: URL, _ storage: SettingsFileStorage) -> SliceRead {
    do {
      return .data(try storage.load(url))
    } catch {
      return Self.isFileAbsent(error) ? .absent : .unreadable
    }
  }

  /// True only when a read failed because the file does not exist.
  private static func isFileAbsent(_ error: any Error) -> Bool {
    if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
    if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
    return false
  }
}
nonisolated extension SharedReaderKey where Self == SettingsFileKey.Default {
  public static var settingsFile: Self {
    Self[SettingsFileKey(), default: .default]
  }
}
