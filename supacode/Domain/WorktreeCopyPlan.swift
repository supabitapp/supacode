import Foundation

/// The ignored / untracked files that survive `supaignore` filtering and will
/// be copied into a freshly created worktree.
nonisolated struct WorktreeCopyPlan: Equatable, Sendable {
  let ignored: [String]
  let untracked: [String]

  // Private so a plan can only be built through `survivors`, which enforces the
  // pruning of `.git` and nested-repo entries.
  private init(ignored: [String], untracked: [String]) {
    self.ignored = ignored
    self.untracked = untracked
  }

  var isEmpty: Bool { ignored.isEmpty && untracked.isEmpty }

  /// Drops the `supaignore`-matched `excluded` set and paths that must never be
  /// copied: `.git`, and nested repos / worktrees (git collapses those to one
  /// trailing-slash entry, so copying verbatim would recurse the whole subtree).
  static func survivors(
    ignoredCandidates: [String],
    untrackedCandidates: [String],
    excluded: Set<String>
  ) -> WorktreeCopyPlan {
    // One shared `seen` across both categories so a path can never land in both
    // lists (and be copied / counted twice); ignored wins.
    var seen: Set<String> = []
    let ignored = retained(from: ignoredCandidates, excluded: excluded, seen: &seen)
    let untracked = retained(from: untrackedCandidates, excluded: excluded, seen: &seen)
    return WorktreeCopyPlan(ignored: ignored, untracked: untracked)
  }

  private static func retained(
    from candidates: [String], excluded: Set<String>, seen: inout Set<String>
  ) -> [String] {
    var result: [String] = []
    for candidate in candidates {
      guard !excluded.contains(candidate) else { continue }
      guard !isProtected(candidate) else { continue }
      guard seen.insert(candidate).inserted else { continue }
      result.append(candidate)
    }
    return result
  }

  private static func isProtected(_ path: String) -> Bool {
    // A trailing slash marks a collapsed nested repo / worktree entry.
    if path.hasSuffix("/") { return true }
    if path == ".git" || path.hasPrefix(".git/") { return true }
    return false
  }
}
