import Dependencies
import Foundation
import Sharing

public nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  public let repositoryID: String

  public init(repositoryID: String) {
    self.repositoryID = repositoryID
  }
}

public nonisolated struct RepositorySettingsKey: SharedKey {
  public let repositoryID: String
  public let rootURL: URL
  public let host: RemoteHost?

  public init(rootURL: URL, host: RemoteHost? = nil) {
    self.rootURL = rootURL.standardizedFileURL
    self.host = host
    if let host {
      // Brand remote keys with the host (matching `RepositoryLocation.id`) so
      // two hosts at the same path can't share settings, and so a local repo
      // at that path keeps its own bare-path key.
      repositoryID = host.authority + self.rootURL.path(percentEncoded: false)
    } else {
      repositoryID = self.rootURL.path(percentEncoded: false)
    }
  }

  public var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  /// The repo's decoded `supacode.json`, or `nil` when it owns none.
  /// A file that is present but unusable (unreadable, or undecodable) resolves to a
  /// failure rather than to `nil`: `save` must be able to tell "no local file" from
  /// "a local file I could not read", or it would overwrite the latter with the
  /// defaults `load` fell back to.
  private func loadLocalSettings() -> Result<RepositorySettings, any Error>? {
    // Remote repos never own a local `supacode.json`; the synthetic `rootURL`
    // points at the remote path, which must not be read off the local disk.
    guard host == nil else { return nil }
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)

    let localData: Data
    do {
      localData = try repositoryLocalSettingsStorage.load(repositorySettingsURL)
    } catch {
      // Owning no `supacode.json` is the norm. Any other read failure (permissions, a
      // stalled mount) leaves a file on disk that still wins the next successful read,
      // so it must not be treated as absent: persisting the user's change anywhere else
      // would silently revert it.
      guard !RepositoryLocalSettingsStorage.isMissingFile(error) else { return nil }
      return .failure(error)
    }

    do {
      return .success(try JSONDecoder().decode(RepositorySettings.self, from: localData))
    } catch {
      return .failure(error)
    }
  }

  /// Reads the repository's settings straight from storage: the local `supacode.json`
  /// first, then the global settings file, then `initialValue`, then the defaults.
  ///
  /// Callers that need the file's *current* contents must use this rather than
  /// `@Shared(.repositorySettings(...))`. Those references are cached, and anything
  /// holding one strongly (every live `WorktreeTerminalState` holds a `SharedReader`
  /// for its worktree's repository) keeps that entry alive, so constructing another
  /// hands back the value loaded when the first one was created. `subscribe` is a no-op,
  /// so nothing ever re-loads it: read through the cache and a `supacode.json` edited
  /// out of band stays invisible for the lifetime of that terminal.
  public func currentSettings(initialValue: RepositorySettings? = nil) -> RepositorySettings {
    switch loadLocalSettings() {
    case .success(let settings):
      RepositorySettingsFailureLog.shared.clear(repositoryID)
      return settings
    case .failure(let error):
      if RepositorySettingsFailureLog.shared.shouldReport(error, .read, for: repositoryID) {
        let path = SupacodePaths.repositorySettingsURL(for: rootURL).path(percentEncoded: false)
        SupaLogger("Settings").warning(
          "Unable to read repository settings at \(path): \(error); falling back to global settings."
        )
      }
    case nil:
      RepositorySettingsFailureLog.shared.clear(repositoryID)
    }

    // A load must never write. `withLock` fires an observation mutation and a
    // full settings-file save even when the closure changes nothing, so seeding
    // defaults here re-invalidates every `settingsFile` observer mid-read. A
    // reader that observes `settingsFile` then re-renders, re-loads, and loops.
    // `save` still creates the entry on the first real change.
    @Shared(.settingsFile) var settingsFile: SettingsFile
    return settingsFile.repositories[repositoryID] ?? initialValue ?? .default
  }

  public func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    continuation.resume(returning: currentSettings(initialValue: context.initialValue))
  }

  public func subscribe(
    context _: LoadContext<RepositorySettings>,
    subscriber _: SharedSubscriber<RepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(
    _ value: RepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    // Mirror `load`: only a local repo may persist to an on-disk `supacode.json`.
    switch loadLocalSettings() {
    case .success:
      @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
      let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
        RepositorySettingsFailureLog.shared.clear(repositoryID)
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
      return

    case .failure(let error):
      // Never overwrite a `supacode.json` we could not read. `load` fell back to the
      // global settings, so encoding `value` over it would replace the user's file (a
      // merge conflict, a stray comma, a permissions blip) with the defaults that
      // failure produced, destroying their scripts. Persist globally and leave it
      // intact, knowing the local file out-votes that copy once it reads again.
      if RepositorySettingsFailureLog.shared.shouldReport(error, .save, for: repositoryID) {
        let path = SupacodePaths.repositorySettingsURL(for: rootURL).path(percentEncoded: false)
        SupaLogger("Settings").error(
          "Refusing to overwrite unreadable repository settings at \(path); persisting to global settings."
        )
      }

    case nil:
      break
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    $settingsFile.withLock {
      $0.repositories[repositoryID] = value
    }
    continuation.resume()
  }
}
/// Remembers which repository's `supacode.json` last failed, and why.
///
/// Every repository is re-read on the periodic refresh, on activation, and on every
/// sidebar selection, and the Settings pane saves on every keystroke. Logging each
/// failure would turn one broken file into a line every few seconds, drowning the
/// signal it exists to carry.
nonisolated final class RepositorySettingsFailureLog: @unchecked Sendable {
  static let shared = RepositorySettingsFailureLog()

  /// Reading and saving fail for the same reason but say different things, and the user
  /// needs to hear that a write was refused even if the read already complained.
  enum Operation: String {
    case read
    case save
  }

  private let lock = NSLock()
  private var reasonByKey: [String: String] = [:]

  /// Whether this failure is worth logging, meaning it is not the one already reported
  /// for that repository and operation.
  func shouldReport(_ error: any Error, _ operation: Operation, for repositoryID: String) -> Bool {
    let reason = String(describing: error)
    lock.lock()
    defer { lock.unlock() }
    let key = "\(operation.rawValue):\(repositoryID)"
    guard reasonByKey[key] != reason else { return false }
    reasonByKey[key] = reason
    return true
  }

  /// Forgets the repository's last failure, so breaking again after a clean read is
  /// reported rather than swallowed as a repeat.
  func clear(_ repositoryID: String) {
    lock.lock()
    defer { lock.unlock() }
    for operation in [Operation.read, .save] {
      reasonByKey["\(operation.rawValue):\(repositoryID)"] = nil
    }
  }
}

nonisolated extension SharedReaderKey where Self == RepositorySettingsKey.Default {
  public static func repositorySettings(_ rootURL: URL, host: RemoteHost? = nil) -> Self {
    Self[RepositorySettingsKey(rootURL: rootURL, host: host), default: .default]
  }
}
