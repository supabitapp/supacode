import Foundation

/// One entry of a listed directory, named relative to that directory.
nonisolated struct FileExplorerEntry: Hashable, Sendable {
  let name: String
  /// True for real directories and for symbolic links that resolve to one, so
  /// both render as expandable rows.
  let isDirectory: Bool
  let isSymbolicLink: Bool
}

/// Immutable snapshot of one non-recursive directory read: sorted
/// directories-first, capped at the requested limit.
nonisolated struct FileExplorerListing: Equatable, Sendable {
  let entries: [FileExplorerEntry]
  /// Entry count before the cap, so the UI can offer loading more.
  let totalCount: Int
  /// The directory's mtime, statted before the read so a change landing
  /// mid-read still registers as changed on the next staleness sweep.
  let modificationDate: Date?

  var isTruncated: Bool { totalCount > entries.count }
}

/// Why a directory read failed, narrowed to what the UI distinguishes.
nonisolated enum FileExplorerListingError: Error, Equatable, Sendable {
  case notFound
  case permissionDenied
  case unreadable
}
