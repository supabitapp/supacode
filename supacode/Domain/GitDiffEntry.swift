import Foundation

struct GitDiffEntry: Identifiable, Hashable, Sendable {
  let path: String
  let kind: Kind
  let additions: Int
  let deletions: Int

  var id: String { path }

  enum Kind: Hashable, Sendable {
    case modified
    case added
    case deleted
    case renamed(from: String)
    case untracked
  }
}
