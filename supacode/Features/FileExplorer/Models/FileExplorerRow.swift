import Foundation

/// Identity of a rendered tree row. Entry rows are keyed by their verbatim
/// root-relative path, so identity is stable across refreshes.
nonisolated enum FileExplorerRowID: Hashable, Sendable {
  case entry(path: String)
  case showMore(directory: String)

  /// The entry's root-relative path; `nil` for non-entry rows.
  var entryPath: String? {
    guard case .entry(let path) = self else { return nil }
    return path
  }
}

/// One flattened, render-ready row of the file tree.
nonisolated struct FileExplorerRow: Equatable, Sendable, Identifiable {
  nonisolated struct Entry: Equatable, Sendable {
    var name: String
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var isExpanded: Bool
    /// The directory's children are being (re)read.
    var isLoading: Bool
    /// The directory's last read failed; expanding again retries.
    var failure: FileExplorerListingError?
  }

  nonisolated enum Kind: Equatable, Sendable {
    case entry(Entry)
    /// Tail row of a capped listing; activating loads the next chunk.
    /// `isLoading` disables it while its directory re-lists, since a tap
    /// during a re-list would otherwise be silently dropped.
    case showMore(remaining: Int, isLoading: Bool)
  }

  /// The entry's root-relative path, or the listed directory's for a
  /// show-more row.
  var path: String
  var depth: Int
  var kind: Kind

  /// Derived so an id case can never disagree with the row's kind.
  var id: FileExplorerRowID {
    switch kind {
    case .entry: .entry(path: path)
    case .showMore: .showMore(directory: path)
    }
  }
}
