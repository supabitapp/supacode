import Foundation

/// Copies a `supaignore`-filtered set of relative paths from a source worktree
/// into a freshly created one. Best-effort per entry so a single unreadable
/// file can't abort the rest, matching `wt`'s `cp ... || true` semantics.
nonisolated enum WorktreeArtifactCopier {
  struct Outcome: Equatable, Sendable {
    var copied: Int
    var failed: Int
    var firstErrorDescription: String?
  }

  static func copy(relativePaths: [String], from source: URL, to destination: URL) -> Outcome {
    let fileManager = FileManager.default
    let sourceRoot = source.standardizedFileURL
    let destinationRoot = destination.standardizedFileURL
    var copied = 0
    var failed = 0
    var firstErrorDescription: String?
    for relativePath in relativePaths {
      let sourceURL = sourceRoot.appending(path: relativePath)
      // lstat semantics (does not follow the final symlink): still copies a
      // symlink whose target is missing or outside the tree, like `wt`'s `cp -P`.
      do {
        _ = try fileManager.attributesOfItem(atPath: sourceURL.path(percentEncoded: false))
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        // Vanished between enumeration and copy: skip without counting a failure.
        continue
      } catch {
        // Present but unreadable (e.g. a parent with no permission): surface it
        // rather than silently under-copy.
        failed += 1
        if firstErrorDescription == nil {
          firstErrorDescription = error.localizedDescription
        }
        continue
      }
      let destinationURL = destinationRoot.appending(path: relativePath)
      // The base ref may have checked a parent out as a symlink; copying through
      // it would escape the worktree, so refuse and report it.
      guard !hasSymlinkedAncestor(of: relativePath, under: destinationRoot) else {
        failed += 1
        if firstErrorDescription == nil {
          firstErrorDescription = "\(relativePath) skipped: a parent directory is a symlink."
        }
        continue
      }
      // A committed-then-ignored file is already checked out at the
      // destination; never clobber the worktree's own version.
      guard !fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) else { continue }
      do {
        try fileManager.createDirectory(
          at: destinationURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        copied += 1
      } catch {
        failed += 1
        if firstErrorDescription == nil {
          firstErrorDescription = error.localizedDescription
        }
      }
    }
    return Outcome(copied: copied, failed: failed, firstErrorDescription: firstErrorDescription)
  }

  /// True when an existing ancestor of `relativePath` under `root` is a symlink.
  /// `isSymbolicLinkKey` reports the item itself (no follow), so a symlinked
  /// parent is caught before the copy writes through it.
  private static func hasSymlinkedAncestor(of relativePath: String, under root: URL) -> Bool {
    var current = root
    for component in relativePath.split(separator: "/").dropLast() {
      current = current.appending(path: String(component))
      let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true { return true }
    }
    return false
  }
}
