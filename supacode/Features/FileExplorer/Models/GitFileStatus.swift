import Foundation

/// Uncommitted git state of a single path, split into git's two independent
/// axes: `index` (staged vs HEAD) and `worktree` (unstaged vs index). A file is
/// routinely dirty on both (e.g. staged then edited again).
nonisolated struct GitFileStatus: Equatable, Sendable {
  var index: GitChangeKind?
  var worktree: GitChangeKind?
  var isUntracked = false
  var isIgnored = false
  var isConflicted = false

  /// A change worth decorating a row for (drives colors, letters, and the
  /// collapsed-folder rollup). Ignored-only entries don't count.
  var hasVisibleChange: Bool {
    isConflicted || isUntracked || index != nil || worktree != nil
  }
}

/// The kind of change on one axis, narrowed to what the tree renders.
/// Type-changes map to `.modified`; renames/copies are disabled in v1 and
/// surface as add + delete, so they never reach here as a distinct kind.
nonisolated enum GitChangeKind: Equatable, Sendable {
  case added
  case modified
  case deleted
}

/// The whole worktree's uncommitted picture from one `git status` call, plus
/// the two prefix indices a per-row lookup needs so resolving a row stays
/// O(1)/O(ignored roots) instead of scanning the change set.
nonisolated struct GitStatusSnapshot: Equatable, Sendable {
  /// Keyed by root-relative path (matching the tree's directory keys), files
  /// only. Directories are decorated by rollup/prefix, never by lookup here.
  var statuses: [String: GitFileStatus] = [:]
  /// Directories that (transitively) contain a change, for the collapsed dot.
  var changedAncestors: Set<String> = []
  /// Reported ignored roots (trailing slash stripped), for prefix-dimming a
  /// whole ignored subtree without enumerating it.
  var ignoredPrefixes: Set<String> = []

  static let empty = GitStatusSnapshot()

  /// Row decoration for `path`, or `nil` when the row carries no git signal.
  func decoration(for path: String, isDirectory: Bool, isExpanded: Bool) -> GitRowDecoration? {
    guard isDirectory else { return fileDecoration(for: path) }
    if isIgnored(path) { return .ignored }
    // An expanded folder's children carry their own glyphs, so the rollup dot
    // would just be redundant noise.
    guard !isExpanded, changedAncestors.contains(path) else { return nil }
    return .directoryDot
  }

  private func fileDecoration(for path: String) -> GitRowDecoration? {
    guard let status = statuses[path] else {
      return isIgnored(path) ? .ignored : nil
    }
    if status.isConflicted { return .file(state: .conflicted, isStaged: false) }
    if status.isUntracked { return .file(state: .added, isStaged: false) }
    if status.isIgnored { return .ignored }
    // Staged content is the primary signal (a both-staged-and-edited file reads
    // as staged and folds its remaining worktree delta in on "Stage").
    let isStaged = status.index != nil
    guard let kind = status.index ?? status.worktree else {
      return isIgnored(path) ? .ignored : nil
    }
    return .file(state: kind.fileState, isStaged: isStaged)
  }

  /// Whether `path` sits at or under a reported ignored root.
  private func isIgnored(_ path: String) -> Bool {
    guard !ignoredPrefixes.isEmpty else { return false }
    if ignoredPrefixes.contains(path) { return true }
    return ignoredPrefixes.contains { path.hasPrefix($0 + "/") }
  }
}

/// A resolved, presentation-ready row signal. The view maps `state` to a
/// letter, tint, and strikethrough; the model stays free of AppKit colors.
nonisolated enum GitRowDecoration: Equatable, Sendable {
  case file(state: FileState, isStaged: Bool)
  /// Gitignored: the label dims to tertiary, no letter.
  case ignored
  /// A collapsed directory containing changes: a neutral rollup dot.
  case directoryDot

  nonisolated enum FileState: Equatable, Sendable {
    case added
    case modified
    case deleted
    case conflicted
  }
}

extension GitChangeKind {
  fileprivate nonisolated var fileState: GitRowDecoration.FileState {
    switch self {
    case .added: .added
    case .modified: .modified
    case .deleted: .deleted
    }
  }
}

extension GitStatusSnapshot {
  /// Parses `git status --porcelain=v2 -z` output into a snapshot. The `-z`
  /// stream is NUL-delimited and record-type-aware: the first byte selects the
  /// format, and a `2` (rename/copy) record spans a second NUL token for its
  /// original path, so a flat split would desync the whole stream after one
  /// rename. Renames are disabled in v1, but the parser handles them so
  /// re-enabling `-M` is a one-line flag flip.
  nonisolated static func parse(porcelainV2 output: String) -> GitStatusSnapshot {
    var statuses: [String: GitFileStatus] = [:]
    var ignoredPrefixes: Set<String> = []
    let records = output.split(separator: "\0", omittingEmptySubsequences: false)
    var index = 0
    while index < records.count {
      let record = records[index]
      index += 1
      guard let first = record.first else { continue }
      switch first {
      case "1":
        parseOrdinary(record, into: &statuses)
      case "2":
        parseRenamed(record, into: &statuses)
        // Consume the paired original-path token.
        index += 1
      case "u":
        parseUnmerged(record, into: &statuses)
      case "?":
        let path = normalizedPath(record.dropFirst(2))
        statuses[path, default: GitFileStatus()].isUntracked = true
      case "!":
        ignoredPrefixes.insert(normalizedPath(record.dropFirst(2)))
      default:
        break
      }
    }
    return GitStatusSnapshot(
      statuses: statuses,
      changedAncestors: changedAncestors(of: statuses),
      ignoredPrefixes: ignoredPrefixes
    )
  }

  private nonisolated static func parseOrdinary(_ record: Substring, into statuses: inout [String: GitFileStatus]) {
    // "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>": 8 fixed fields precede the
    // path, which may itself contain spaces, so cap the split.
    let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
    guard fields.count == 9, fields[1].count == 2 else { return }
    let xy = fields[1]
    let path = normalizedPath(fields[8])
    var status = statuses[path] ?? GitFileStatus()
    status.index = changeKind(xy.first)
    status.worktree = changeKind(xy.dropFirst().first)
    statuses[path] = status
  }

  private nonisolated static func parseRenamed(_ record: Substring, into statuses: inout [String: GitFileStatus]) {
    // "2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>": 9 fields precede
    // the new path; the original path is the following NUL token (consumed by
    // the caller). A rename is a staged move, so the new path carries X.
    let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
    guard fields.count == 10, fields[1].count == 2 else { return }
    let xy = fields[1]
    let path = normalizedPath(fields[9])
    var status = statuses[path] ?? GitFileStatus()
    status.index = changeKind(xy.first) ?? .added
    status.worktree = changeKind(xy.dropFirst().first)
    statuses[path] = status
  }

  private nonisolated static func parseUnmerged(_ record: Substring, into statuses: inout [String: GitFileStatus]) {
    // "u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>": 10 fixed fields.
    let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
    guard fields.count == 11 else { return }
    let path = normalizedPath(fields[10])
    statuses[path, default: GitFileStatus()].isConflicted = true
  }

  private nonisolated static func changeKind(_ code: Character?) -> GitChangeKind? {
    switch code {
    case "A": .added
    case "D": .deleted
    case "M", "T", "R", "C": .modified
    default: nil
    }
  }

  /// Every directory that transitively contains a change, so a collapsed folder
  /// can show a rollup dot without scanning the change set per row.
  private nonisolated static func changedAncestors(of statuses: [String: GitFileStatus]) -> Set<String> {
    var ancestors: Set<String> = []
    for (path, status) in statuses where status.hasVisibleChange {
      var components = path.split(separator: "/")
      guard components.count > 1 else { continue }
      components.removeLast()
      var prefix = ""
      for component in components {
        prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
        ancestors.insert(prefix)
      }
    }
    return ancestors
  }

  /// Git reports wholly-ignored (and empty untracked) directories with a
  /// trailing slash; strip it so keys match the tree's slash-free paths.
  private nonisolated static func normalizedPath(_ raw: Substring) -> String {
    raw.hasSuffix("/") ? String(raw.dropLast()) : String(raw)
  }
}
