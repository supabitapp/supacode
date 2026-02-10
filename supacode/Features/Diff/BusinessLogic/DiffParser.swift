import Foundation

nonisolated enum DiffParser {
  struct NumstatEntry {
    let path: String
    let added: Int
    let deleted: Int
  }

  nonisolated static func parseStatusPorcelain(_ output: String) -> [GitDiffEntry] {
    guard !output.isEmpty else { return [] }
    let entries = output.split(separator: "\0", omittingEmptySubsequences: false)
    var result: [GitDiffEntry] = []
    var index = entries.startIndex
    while index < entries.endIndex {
      let entry = entries[index]
      guard entry.count >= 3 else {
        index = entries.index(after: index)
        continue
      }
      let statusChars = entry.prefix(2)
      let path = String(entry.dropFirst(3))
      guard !path.isEmpty else {
        index = entries.index(after: index)
        continue
      }
      let indexStatus = statusChars.first ?? " "
      let worktreeStatus = statusChars.dropFirst().first ?? " "
      let kind: GitDiffEntry.Kind
      switch (indexStatus, worktreeStatus) {
      case ("R", _):
        let nextIndex = entries.index(after: index)
        let from = nextIndex < entries.endIndex ? String(entries[nextIndex]) : path
        kind = .renamed(from: from)
        index = entries.index(after: nextIndex)
        result.append(GitDiffEntry(path: path, kind: kind, additions: 0, deletions: 0))
        continue
      case ("?", "?"):
        kind = .untracked
      case ("A", _), (_, "A"):
        kind = .added
      case ("D", _), (_, "D"):
        kind = .deleted
      default:
        kind = .modified
      }
      result.append(GitDiffEntry(path: path, kind: kind, additions: 0, deletions: 0))
      index = entries.index(after: index)
    }
    return result
  }

  nonisolated static func parseNumstat(_ output: String) -> [NumstatEntry] {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed.split(whereSeparator: \.isNewline).compactMap { line in
      let parts = line.split(separator: "\t")
      guard parts.count >= 3 else { return nil }
      let added = Int(parts[0]) ?? 0
      let deleted = Int(parts[1]) ?? 0
      let path = String(parts[2...].joined(separator: "\t"))
      return NumstatEntry(path: path, added: added, deleted: deleted)
    }
  }

  nonisolated static func enrichEntries(
    _ entries: [GitDiffEntry],
    with numstat: [NumstatEntry]
  ) -> [GitDiffEntry] {
    let statsByPath = Dictionary(
      numstat.map { ($0.path, $0) },
      uniquingKeysWith: { _, last in last }
    )
    return entries.map { entry in
      if let stats = statsByPath[entry.path] {
        return GitDiffEntry(path: entry.path, kind: entry.kind, additions: stats.added, deletions: stats.deleted)
      }
      return entry
    }
  }
}
