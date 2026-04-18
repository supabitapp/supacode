import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

/// Stable identity for the sidebar `SharedKey`. Mirrors
/// `LayoutsKeyID` — a dummy struct so `SharedKey.id` can
/// discriminate this key from every other `SharedKey` in the app.
nonisolated struct SidebarKeyID: Hashable, Sendable {}

/// Dependency key that hands back the file URL `SidebarKey` reads
/// from and writes to. Production wires to `SupacodePaths.sidebarURL`;
/// tests override with a temp-directory URL so the SharedKey can be
/// exercised hermetically (the live corrupt-file path renames the
/// bad file, which we don't want touching the user's real
/// `~/.supacode/sidebar.json`).
public nonisolated enum SidebarFileURLKey: DependencyKey {
  public static var liveValue: URL { SupacodePaths.sidebarURL }
  public static var previewValue: URL { SupacodePaths.sidebarURL }
  public static var testValue: URL {
    FileManager.default.temporaryDirectory
      .appending(
        path: "supacode-sidebar-test-\(UUID().uuidString).json",
        directoryHint: .notDirectory
      )
  }
}

extension DependencyValues {
  public nonisolated var sidebarFileURL: URL {
    get { self[SidebarFileURLKey.self] }
    set { self[SidebarFileURLKey.self] = newValue }
  }
}

/// Custom `SharedKey` that persists the nested `SidebarState` to the
/// `\.sidebarFileURL` dependency via the shared `SettingsFileStorage`.
/// Modelled on `LayoutsKey` — same load/save/subscribe shape, same
/// atomic-write guarantee from the live storage.
nonisolated struct SidebarKey: SharedKey {
  private static let logger = SupaLogger("Sidebar")

  var id: SidebarKeyID { SidebarKeyID() }

  func load(
    context _: LoadContext<SidebarState>,
    continuation: LoadContinuation<SidebarState>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.sidebarFileURL) var url
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      // File does not exist yet — expected on first run and on
      // installs whose legacy state hasn't been migrated.
      continuation.resumeReturningInitialValue()
      return
    }
    do {
      let state = try JSONDecoder().decode(SidebarState.self, from: data)
      continuation.resume(returning: state)
    } catch {
      // Move the corrupt file aside before falling back to an empty
      // state — otherwise the next `save` atomically overwrites the
      // bytes we might need to recover from. A decode failure always
      // logs at warning level so the operator sees the corruption;
      // if the subsequent rename also fails, we log a second warning
      // line so the double-failure is unambiguous in the logs. When
      // the corrupt file has already been renamed by a prior run we
      // skip the second log entirely. Non-recoverable without manual
      // intervention, but leaving the app stuck in a "refuse to
      // save" sentinel state would create a worse UX.
      Self.logger.warning(
        "Failed to decode sidebar state from \(url.path(percentEncoded: false)): \(error)"
      )
      Self.renameCorruptFile(at: url)
      continuation.resumeReturningInitialValue()
    }
  }

  /// Moves a corrupt `sidebar.json` aside to
  /// `sidebar.json.corrupt-<ISO8601>` so an atomic save from the
  /// empty default doesn't overwrite the only on-disk copy of the
  /// user's sidebar curation. The `\.settingsFileStorage` dep only
  /// exposes `load` / `save`, so the rename goes through
  /// `FileManager` directly — a missing or already-renamed file
  /// returns without surfacing; the caller always proceeds to the
  /// empty fallback.
  private static func renameCorruptFile(at url: URL) {
    let fileManager = FileManager.default
    let sourcePath = url.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: sourcePath) else {
      return
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date()).replacing(":", with: "-")
    let destination = url.deletingLastPathComponent()
      .appending(
        path: "\(url.lastPathComponent).corrupt-\(timestamp)",
        directoryHint: .notDirectory
      )
    do {
      try fileManager.moveItem(at: url, to: destination)
    } catch {
      Self.logger.warning(
        """
        Failed to rename corrupt sidebar file to \(destination.lastPathComponent): \(error). \
        Next save WILL overwrite the corrupt bytes.
        """
      )
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
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.sidebarFileURL) var url
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      try storage.save(data, url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == SidebarKey.Default {
  static var sidebar: Self {
    Self[SidebarKey(), default: SidebarState()]
  }
}
