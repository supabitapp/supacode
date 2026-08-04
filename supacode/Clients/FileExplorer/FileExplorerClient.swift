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
    }
  )

  /// Benign defaults so fixtures with fake paths keep working; tests that
  /// exercise listing override explicitly.
  static let testValue = FileExplorerClient(
    list: { _, _ in FileExplorerListing(entries: [], totalCount: 0, modificationDate: nil) },
    modificationDates: { _ in [:] }
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
