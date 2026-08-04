import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Filesystem reads for the files inspector. Every closure hops off the main
/// actor: listing and sorting a large directory must never block the UI.
struct FileExplorerClient: Sendable {
  /// Lists `directory` non-recursively: dotfiles included, `.git` excluded,
  /// sorted directories-first then Finder-like, capped at `limit`.
  var list: @Sendable (_ directory: URL, _ limit: Int) async throws(FileExplorerListingError) -> FileExplorerListing
  /// Content-modification dates of `directories`, skipping entries that fail
  /// to stat. Directory mtime moves on entry create/delete/rename, which is
  /// all the tree renders, so this drives the staleness sweep.
  var modificationDates: @Sendable (_ directories: [URL]) async -> [URL: Date]
  /// The subset of `names` that already exist in `directory`, so a move or
  /// paste can ask the user before overwriting.
  var existingNames: @Sendable (_ directory: URL, _ names: [String]) async -> Set<String>
  /// The names among `sources` that are directories colliding with a same-named
  /// directory in `directory`, so the prompt can offer Merge.
  var mergeableNames: @Sendable (_ directory: URL, _ sources: [URL]) async -> Set<String>
  /// Moves or copies `source` into `directory` under `name`, resolving a name
  /// collision per `policy`.
  var transfer:
    @Sendable (
      _ source: URL, _ directory: URL, _ name: String,
      _ operation: FileTransferOperation, _ policy: FileConflictPolicy
    ) async throws -> Void
  /// Renames `source` to `newName` in place, throwing on a collision.
  var rename: @Sendable (_ source: URL, _ newName: String) async throws -> Void
  /// Moves `url` to the system Trash, recoverable by the user.
  var moveToTrash: @Sendable (_ url: URL) async throws -> Void
  /// Creates an empty file or folder in `directory` under a free name derived
  /// from `name`, returning the name it landed on.
  var createItem: @Sendable (_ directory: URL, _ name: String, _ isDirectory: Bool) async throws -> String
}

/// Whether a file transfer relocates the source or duplicates it.
nonisolated enum FileTransferOperation: Equatable, Sendable {
  case move
  case copy
}

/// How a transfer resolves an existing item at the destination name.
nonisolated enum FileConflictPolicy: Equatable, Sendable {
  /// Throw if the name is already taken. The caller passes this only after a
  /// collision check, so it also backstops a name that appeared since.
  case abort
  /// Replace the existing item.
  case overwrite
  /// Land under a Finder-style " copy" name instead.
  case keepBoth
  /// Recursively fold a directory into a same-named one: new entries win,
  /// existing-only entries stay, subfolders recurse. Degrades to overwrite
  /// when either side is not a directory.
  case merge
}

extension FileExplorerClient: DependencyKey {
  static let liveValue = FileExplorerClient(
    list: { directory, limit throws(FileExplorerListingError) in
      do {
        return try await Task.detached(priority: .userInitiated) {
          try listDirectory(at: directory, limit: limit)
        }.value
      } catch {
        guard let listingError = error as? FileExplorerListingError else {
          logger.warning("Untyped listing error folded to unreadable: \(error)")
          throw .unreadable
        }
        throw listingError
      }
    },
    modificationDates: { directories in
      await Task.detached(priority: .utility) {
        contentModificationDates(of: directories)
      }.value
    },
    existingNames: { directory, names in
      // A stat failure reads as "absent" here; the transfer's own throw is the
      // real overwrite guard, so a false negative only skips the prompt.
      await Task.detached(priority: .userInitiated) {
        var present: Set<String> = []
        for name in names
        where FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false)) {
          present.insert(name)
        }
        return present
      }.value
    },
    mergeableNames: { directory, sources in
      await Task.detached(priority: .userInitiated) {
        var names: Set<String> = []
        for source in sources
        where isDirectory(at: source) && isDirectory(at: directory.appending(path: source.lastPathComponent)) {
          names.insert(source.lastPathComponent)
        }
        return names
      }.value
    },
    transfer: { source, directory, name, operation, policy in
      try await Task.detached(priority: .userInitiated) {
        try performTransfer(source: source, directory: directory, name: name, operation: operation, policy: policy)
      }.value
    },
    rename: { source, newName in
      try await Task.detached(priority: .userInitiated) { try renameItem(at: source, to: newName) }.value
    },
    moveToTrash: { url in
      try await Task.detached(priority: .userInitiated) {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      }.value
    },
    createItem: { directory, name, isDirectory in
      try await Task.detached(priority: .userInitiated) {
        let manager = FileManager.default
        let finalName = uniqueName(for: name) {
          manager.fileExists(atPath: directory.appending(path: $0).path(percentEncoded: false))
        }
        let path = directory.appending(path: finalName, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        if isDirectory {
          try manager.createDirectory(at: path, withIntermediateDirectories: false)
        } else {
          // Exclusive atomic create so a racing second create throws instead of
          // truncating the file that just appeared.
          try Data().write(to: path, options: .withoutOverwriting)
        }
        return finalName
      }.value
    }
  )

  /// Benign defaults so fixtures with fake paths keep working; tests that
  /// exercise listing override explicitly.
  static let testValue = FileExplorerClient(
    list: { _, _ in FileExplorerListing(entries: [], totalCount: 0, modificationDate: nil) },
    modificationDates: { _ in [:] },
    existingNames: { _, _ in [] },
    mergeableNames: { _, _ in [] },
    transfer: { _, _, _, _, _ in },
    rename: { _, _ in },
    moveToTrash: { _ in },
    createItem: { _, name, _ in name }
  )
}

extension DependencyValues {
  var fileExplorerClient: FileExplorerClient {
    get { self[FileExplorerClient.self] }
    set { self[FileExplorerClient.self] = newValue }
  }
}

extension FileExplorerClient {
  nonisolated private static let logger = SupaLogger("FileExplorer")

  nonisolated static func listDirectory(at directory: URL, limit: Int) throws -> FileExplorerListing {
    // Defense in depth: a negative cap would trap in `removeSubrange`.
    let limit = max(0, limit)
    let modificationDate = contentModificationDates(of: [directory])[directory]
    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: []
      )
    } catch {
      throw listingError(from: error)
    }
    var entries: [FileExplorerEntry] = []
    entries.reserveCapacity(contents.count)
    for url in contents {
      let name = url.lastPathComponent
      guard name != ".git" else { continue }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      let isSymbolicLink = values?.isSymbolicLink ?? false
      entries.append(
        FileExplorerEntry(
          name: name,
          isDirectory: isDirectory(url, resolvedValues: values, isSymbolicLink: isSymbolicLink),
          isSymbolicLink: isSymbolicLink
        )
      )
    }
    entries.sort { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory {
        return lhs.isDirectory
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    let totalCount = entries.count
    if entries.count > limit {
      entries.removeSubrange(limit...)
    }
    return FileExplorerListing(entries: entries, totalCount: totalCount, modificationDate: modificationDate)
  }

  nonisolated static func contentModificationDates(of directories: [URL]) -> [URL: Date] {
    var dates: [URL: Date] = [:]
    dates.reserveCapacity(directories.count)
    for url in directories {
      // URLs memoize resource values per instance; drop the cache so repeated
      // sweeps over a held URL observe fresh mtimes.
      var uncached = url
      uncached.removeCachedResourceValue(forKey: .contentModificationDateKey)
      guard
        let values = try? uncached.resourceValues(forKeys: [.contentModificationDateKey]),
        let date = values.contentModificationDate
      else { continue }
      dates[url] = date
    }
    return dates
  }

  /// A symlink's own `isDirectory` is false; resolve it so a link to a
  /// directory still renders as an expandable row.
  private nonisolated static func isDirectory(
    _ url: URL,
    resolvedValues: URLResourceValues?,
    isSymbolicLink: Bool
  ) -> Bool {
    guard isSymbolicLink else {
      return resolvedValues?.isDirectory ?? false
    }
    var resolvedIsDirectory: ObjCBool = false
    let resolvedPath = url.resolvingSymlinksInPath().path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &resolvedIsDirectory) else {
      return false
    }
    return resolvedIsDirectory.boolValue
  }

  /// Resolves the destination name against `policy`, then moves or copies.
  /// Keep-both scans for a free " copy" name; overwrite stages the new item
  /// under a temp sibling and swaps it in, so a failed transfer never leaves
  /// the destination deleted with no replacement.
  nonisolated static func performTransfer(
    source: URL,
    directory: URL,
    name: String,
    operation: FileTransferOperation,
    policy: FileConflictPolicy
  ) throws {
    let manager = FileManager.default
    let destination = directory.appending(path: name)
    // Only a real directory landing inside its own subtree recurses; a symlink
    // just copies the link. The reducer pre-filters this, but resolve symlinks
    // here so a worktree under a symlinked prefix can't slip a recursive copy past.
    guard !(isDirectory(at: source) && isSubpath(directory, of: source)) else { return }
    func exists(_ candidate: String) -> Bool {
      manager.fileExists(atPath: directory.appending(path: candidate).path(percentEncoded: false))
    }
    switch policy {
    case .abort:
      try placeItem(from: source, at: destination, operation: operation)
    case .keepBoth:
      try placeItem(from: source, at: directory.appending(path: uniqueName(for: name, isTaken: exists)), operation: operation)
    case .overwrite:
      try replaceItem(from: source, at: destination, operation: operation)
    case .merge:
      // Only a directory folded into a same-named directory merges; anything
      // else replaces, matching the alert that offered Merge for dir-on-dir.
      guard isDirectory(at: source), exists(name), isDirectory(at: destination) else {
        try replaceItem(from: source, at: destination, operation: operation)
        return
      }
      guard source.standardizedFileURL != destination.standardizedFileURL else { return }
      try mergeDirectory(from: source, into: destination, operation: operation)
      // A moved source is now emptied of its merged contents; drop the shell.
      if operation == .move { try? manager.removeItem(at: source) }
    }
  }

  /// Moves or copies `source` to `destination`, throwing if it exists.
  private nonisolated static func placeItem(
    from source: URL, at destination: URL, operation: FileTransferOperation
  ) throws {
    switch operation {
    case .move: try FileManager.default.moveItem(at: source, to: destination)
    case .copy: try FileManager.default.copyItem(at: source, to: destination)
    }
  }

  /// Replaces `destination` with `source`, staging under a temp sibling then
  /// swapping atomically so a failed transfer never leaves the destination
  /// deleted with no replacement. Replacing an item with itself is a no-op.
  private nonisolated static func replaceItem(
    from source: URL, at destination: URL, operation: FileTransferOperation
  ) throws {
    let manager = FileManager.default
    guard source.standardizedFileURL != destination.standardizedFileURL else { return }
    guard manager.fileExists(atPath: destination.path(percentEncoded: false)) else {
      try placeItem(from: source, at: destination, operation: operation)
      return
    }
    let staged = destination.deletingLastPathComponent().appending(path: ".supacode-replace-\(UUID().uuidString)")
    try placeItem(from: source, at: staged, operation: operation)
    do {
      // Atomic swap: the old destination survives until the staged item is in
      // place, so a failure here never destroys it.
      _ = try manager.replaceItemAt(destination, withItemAt: staged)
    } catch {
      // A move already consumed the source, so restore the staged item rather
      // than stranding the only copy; a copy can safely drop the duplicate.
      switch operation {
      case .move: try? manager.moveItem(at: staged, to: source)
      case .copy: try? manager.removeItem(at: staged)
      }
      throw error
    }
  }

  /// Folds `source`'s entries into `destination`: a same-named subdirectory
  /// recurses, everything else replaces (existing-only entries are untouched).
  private nonisolated static func mergeDirectory(
    from source: URL, into destination: URL, operation: FileTransferOperation
  ) throws {
    let manager = FileManager.default
    let entries = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    for entry in entries {
      let target = destination.appending(path: entry.lastPathComponent)
      if isDirectory(at: entry), isDirectory(at: target) {
        try mergeDirectory(from: entry, into: target, operation: operation)
      } else {
        try replaceItem(from: entry, at: target, operation: operation)
      }
    }
  }

  /// A real directory, not a symlink to one: `fileExists(isDirectory:)` follows
  /// links, which would make a merge recurse into (and a move drain) whatever
  /// the link points at, so resolve the flags without traversing.
  private nonisolated static func isDirectory(at url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    return (values?.isDirectory ?? false) && !(values?.isSymbolicLink ?? false)
  }

  /// Whether `url` is `ancestor` itself or nested inside it, comparing
  /// symlink-resolved paths so a symlinked prefix can't hide the containment.
  private nonisolated static func isSubpath(_ url: URL, of ancestor: URL) -> Bool {
    func resolvedPath(_ url: URL) -> String {
      var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
      if path.count > 1, path.hasSuffix("/") { path.removeLast() }
      return path
    }
    let ancestorPath = resolvedPath(ancestor)
    let target = resolvedPath(url)
    return target == ancestorPath || target.hasPrefix(ancestorPath + "/")
  }

  /// Renames `source` to `newName` in its own directory. A case-only change on
  /// a case-insensitive volume goes through a temp name, since moving straight
  /// to the new case reads as "already exists".
  nonisolated static func renameItem(at source: URL, to newName: String) throws {
    let manager = FileManager.default
    let directory = source.deletingLastPathComponent()
    let destination = directory.appending(path: newName)
    let current = source.lastPathComponent
    guard current != newName, current.lowercased() == newName.lowercased() else {
      try manager.moveItem(at: source, to: destination)
      return
    }
    let staged = directory.appending(path: ".supacode-rename-\(UUID().uuidString)")
    try manager.moveItem(at: source, to: staged)
    do {
      try manager.moveItem(at: staged, to: destination)
    } catch {
      // The source is already at the temp name, so put it back rather than
      // stranding it there if the second move fails.
      try? manager.moveItem(at: staged, to: source)
      throw error
    }
  }

  /// A Finder-style non-colliding name: "foo.txt" -> "foo copy.txt" -> "foo
  /// copy 2.txt". The suffix lands before the final extension.
  nonisolated static func uniqueName(for name: String, isTaken: (String) -> Bool) -> String {
    guard isTaken(name) else { return name }
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    let compose: (String) -> String = { stem in ext.isEmpty ? stem : stem + "." + ext }
    var candidate = compose("\(base) copy")
    var counter = 2
    while isTaken(candidate) {
      candidate = compose("\(base) copy \(counter)")
      counter += 1
    }
    return candidate
  }

  private nonisolated static func listingError(from error: Error) -> FileExplorerListingError {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
      switch nsError.code {
      case CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue:
        return .notFound
      case CocoaError.fileReadNoPermission.rawValue:
        return .permissionDenied
      default:
        break
      }
    }
    if let posixError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
      posixError.domain == NSPOSIXErrorDomain
    {
      switch posixError.code {
      case Int(ENOENT), Int(ENOTDIR):
        return .notFound
      case Int(EACCES), Int(EPERM):
        return .permissionDenied
      default:
        break
      }
    }
    logger.warning("Unmapped listing error folded to unreadable: \(nsError.domain) \(nsError.code)")
    return .unreadable
  }
}
