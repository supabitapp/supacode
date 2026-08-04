import Foundation

/// Uncommitted git state of a single path, split into git's two independent
/// axes: `index` (staged vs HEAD) and `worktree` (unstaged vs index). A file is
/// routinely dirty on both (e.g. staged then edited again).
nonisolated struct GitFileStatus: Equatable, Sendable {
  var index: GitChangeKind?
  var worktree: GitChangeKind?
  var isUntracked = false
  var isConflicted = false

  /// A change worth decorating a row for (drives colors, letters, and the
  /// collapsed-folder rollup). Ignored-only entries don't count.
  var hasVisibleChange: Bool {
    isConflicted || isUntracked || index != nil || worktree != nil
  }

  /// A worktree-side change to fold into the index (drives Stage vs Unstage).
  var hasUnstagedChange: Bool { isUntracked || worktree != nil }
  /// An index-side change to unstage.
  var hasStagedChange: Bool { index != nil }

  /// The change state a row renders, or `nil` when clean. Single source of
  /// truth for the file row and the folder rollup, so they can't disagree. A
  /// path carrying an index/worktree change reads by that change even when it
  /// also has an untracked working copy (e.g. `git rm --cached` leaves a staged
  /// deletion plus an untracked copy); only a change-free untracked path is a
  /// pure addition.
  var displayState: GitRowDecoration.FileState? {
    if isConflicted { return .conflicted }
    if let kind = index ?? worktree { return kind.fileState }
    return isUntracked ? .added : nil
  }

  /// How a discard should treat this path, or `nil` when there's nothing to
  /// discard (clean or conflicted). Single source of truth for the reducer,
  /// context menu, and keyboard shortcuts.
  var discardKind: GitDiscardKind? {
    guard !isConflicted else { return nil }
    // Only a brand-new file with no committed version is removed to the Trash.
    // A path that still has an index/worktree change exists in HEAD even when
    // its working copy reads as untracked (e.g. after `git rm --cached`), so it
    // is restored, not trashed.
    if index == .added || (isUntracked && index == nil && worktree == nil) { return .trash }
    guard index != nil || worktree != nil else { return nil }
    return .restore
  }
}

/// What "discard" does to a path: remove a new file to the Trash, or restore a
/// tracked change to its committed version.
nonisolated enum GitDiscardKind: Equatable, Sendable {
  case trash
  case restore
}

/// Why a stage/unstage/discard failed, narrowed to what the alert distinguishes.
/// Carries the path so the alert can name the file.
nonisolated struct GitOperationError: Error, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    /// Another git process holds `.git/index.lock`.
    case locked
    case failed
  }

  let path: String
  let kind: Kind
}

/// The kind of change on one axis, narrowed to what the tree renders.
nonisolated enum GitChangeKind: Equatable, Sendable {
  case added
  case modified
  case deleted
}

/// How a collapsed folder's descendant changes roll up. `.modified` dominates
/// when a folder mixes an addition with anything else, so only an all-additions
/// folder reads as added.
nonisolated enum FolderChange: Equatable, Sendable {
  case added
  case modified

  var fileState: GitRowDecoration.FileState {
    switch self {
    case .added: .added
    case .modified: .modified
    }
  }
}

/// The whole worktree's uncommitted picture from one `git status` call, plus
/// prefix sets so a per-row lookup avoids scanning the change set.
nonisolated struct GitStatusSnapshot: Equatable, Sendable {
  /// Keyed by root-relative path (matching the tree's directory keys), files
  /// only. Directories are decorated by rollup/prefix, never by lookup here.
  let statuses: [String: GitFileStatus]
  /// Directories that (transitively) contain a change, keyed to how they roll
  /// up. Absent means no change; presence carries the exact state.
  let changedAncestors: [String: FolderChange]
  /// Reported ignored roots (trailing slash stripped), for prefix-dimming a
  /// whole ignored subtree without enumerating it.
  let ignoredPrefixes: Set<String>

  static let empty = GitStatusSnapshot()

  /// `changedAncestors` is always derived here, never passed in, so the rollup
  /// index can't drift from `statuses`.
  init(statuses: [String: GitFileStatus] = [:], ignoredPrefixes: Set<String> = []) {
    self.statuses = statuses
    self.ignoredPrefixes = ignoredPrefixes
    self.changedAncestors = Self.changedAncestors(of: statuses)
  }

  /// Row decoration for `path`, or `nil` when the row carries no git signal.
  func decoration(for path: String, isDirectory: Bool, isExpanded: Bool) -> GitRowDecoration? {
    guard isDirectory else { return fileDecoration(for: path) }
    if isIgnored(path) { return .ignored }
    // An expanded folder's children carry their own glyphs, so a rollup on it
    // would just be redundant noise.
    guard !isExpanded, let rollup = changedAncestors[path] else { return nil }
    return .file(state: rollup.fileState, isStaged: false)
  }

  private func fileDecoration(for path: String) -> GitRowDecoration? {
    guard let status = statuses[path], let state = status.displayState else {
      return isIgnored(path) ? .ignored : nil
    }
    // Staged content is the primary signal (a both-staged-and-edited file reads
    // as staged and folds its remaining worktree delta in on "Stage").
    return .file(state: state, isStaged: status.hasStagedChange)
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
  /// Gitignored: the row dims, no letter.
  case ignored

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
  /// Parses `git status --porcelain=v2 -z` output into a snapshot. A `2`
  /// (rename) record spans a second NUL token for its original path, so the
  /// loop advances past it rather than treating it as a fresh record.
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
    return GitStatusSnapshot(statuses: statuses, ignoredPrefixes: ignoredPrefixes)
  }

  private nonisolated static func parseOrdinary(_ record: Substring, into statuses: inout [String: GitFileStatus]) {
    // "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>": 8 fixed fields precede the
    // path, which may itself contain spaces, so cap the split.
    let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
    guard fields.count == 9, fields[1].count == 2 else { return }
    let codes = fields[1]
    let path = normalizedPath(fields[8])
    var status = statuses[path] ?? GitFileStatus()
    status.index = changeKind(codes.first)
    status.worktree = changeKind(codes.dropFirst().first)
    statuses[path] = status
  }

  private nonisolated static func parseRenamed(_ record: Substring, into statuses: inout [String: GitFileStatus]) {
    // "2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>": 9 fields precede
    // the new path; the original path is the following NUL token (consumed by
    // the caller). A rename is a staged move, so the new path carries X.
    let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
    guard fields.count == 10, fields[1].count == 2 else { return }
    let codes = fields[1]
    let path = normalizedPath(fields[9])
    var status = statuses[path] ?? GitFileStatus()
    status.index = changeKind(codes.first) ?? .added
    status.worktree = changeKind(codes.dropFirst().first)
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

  /// Every directory that transitively contains a change, keyed to whether it
  /// rolls up as an addition or a modification, so a collapsed folder can show
  /// its rollup letter without scanning the change set per row.
  private nonisolated static func changedAncestors(
    of statuses: [String: GitFileStatus]
  ) -> [String: FolderChange] {
    var rollup: [String: FolderChange] = [:]
    for (path, status) in statuses where status.hasVisibleChange {
      var components = path.split(separator: "/")
      guard components.count > 1 else { continue }
      components.removeLast()
      // Mirror the file row exactly: a folder is an addition only when its file
      // renders as added, so folder and child never disagree.
      let isAddition = status.displayState == .added
      var prefix = ""
      for component in components {
        prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
        // A non-addition anywhere folds the folder to modified; an addition
        // only sets the initial state so a sibling change can't be downgraded.
        if isAddition {
          if rollup[prefix] == nil { rollup[prefix] = .added }
        } else {
          rollup[prefix] = .modified
        }
      }
    }
    return rollup
  }

  /// Git reports wholly-ignored (and empty untracked) directories with a
  /// trailing slash; strip it so keys match the tree's slash-free paths.
  private nonisolated static func normalizedPath(_ raw: Substring) -> String {
    raw.hasSuffix("/") ? String(raw.dropLast()) : String(raw)
  }
}
