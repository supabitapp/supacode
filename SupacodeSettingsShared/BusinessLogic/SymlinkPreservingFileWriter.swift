import Foundation

public nonisolated enum SymlinkPreservingFileWriterError: Error, Equatable {
  /// The destination resolves through a symlink cycle, so there is no real file
  /// to write without clobbering one of the links.
  case symbolicLinkCycle(URL)
  /// The chain exceeds the kernel's symlink-resolution limit, so the loader
  /// could never follow it; refuse rather than write a file it can't read back.
  case symbolicLinkChainTooDeep(URL)
}

/// Atomic file writes that survive a symlinked destination. When the target is a
/// symlink (e.g. a `~/.supacode/settings.json` linked into a dotfiles repo), the
/// write follows the link to its real file so the temp+rename replaces the
/// target, leaving the link intact, instead of overwriting the link with a
/// regular file.
public nonisolated enum SymlinkPreservingFileWriter {
  /// Atomically writes `data` to `url`, following a symlink at `url` so the link
  /// is preserved. Creates the destination's own parent directory when missing,
  /// but never a symlink target's parent (a link into a missing directory fails
  /// the write rather than fabricating a phantom tree there).
  public static func write(_ data: Data, to url: URL) throws {
    let target = try resolvedTarget(for: url)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // The atomic temp+rename happens in the target's directory, so a symlink at
    // `url` is written through and preserved instead of replaced.
    try data.write(to: target, options: [.atomic])
  }

  /// Moves the file at `url` aside to `destination`, preserving a symlink at
  /// `url` by relocating the link's resolved target so the link survives (left
  /// dangling for the next `write` to recreate). Falls back to moving the link
  /// itself when it can't be resolved to a real target (a cycle or an over-deep
  /// chain), where there is nothing else to relocate.
  public static func moveAside(at url: URL, to destination: URL) throws {
    let source: URL
    do {
      source = try resolvedTarget(for: url)
    } catch is SymlinkPreservingFileWriterError {
      source = url
    }
    try FileManager.default.moveItem(at: source, to: destination)
  }

  /// macOS resolves at most MAXSYMLINKS (32) links before ELOOP, so a deeper
  /// chain is one the loader's `Data(contentsOf:)` could never read back.
  private static let maxFollowedSymbolicLinks = 32

  /// Follows a symlink chain at `url` to its final real file. Returns `url`
  /// unchanged when it is not a symlink (including a not-yet-created file).
  /// Relative link targets resolve against the link's real directory so a link
  /// under a symlinked parent still lands on the file the kernel would. Throws
  /// on a cycle or an over-deep chain rather than silently overwriting a link in
  /// the loop, and surfaces a real read error rather than misreading an
  /// unreadable link as a plain file (which would clobber it).
  private static func resolvedTarget(for url: URL) throws -> URL {
    let fileManager = FileManager.default
    var current = url
    var visited: Set<String> = []
    while true {
      let isSymbolicLink: Bool
      do {
        isSymbolicLink = try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false
      } catch CocoaError.fileReadNoSuchFile {
        return current
      }
      guard isSymbolicLink else { return current }
      let linkPath = current.path(percentEncoded: false)
      guard visited.insert(linkPath).inserted else {
        throw SymlinkPreservingFileWriterError.symbolicLinkCycle(url)
      }
      guard visited.count <= Self.maxFollowedSymbolicLinks else {
        throw SymlinkPreservingFileWriterError.symbolicLinkChainTooDeep(url)
      }
      let destination = try fileManager.destinationOfSymbolicLink(atPath: linkPath)
      // A relative target resolves against the link's real directory; an absolute one ignores the base.
      let base =
        destination.hasPrefix("/") ? nil : current.deletingLastPathComponent().resolvingSymlinksInPath()
      current = URL(filePath: destination, directoryHint: .notDirectory, relativeTo: base).standardizedFileURL
    }
  }
}
