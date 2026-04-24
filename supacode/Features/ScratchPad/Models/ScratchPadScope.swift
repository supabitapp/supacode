import Foundation

enum ScratchPadScope: Hashable, Codable, Sendable {
  case global
  case worktree(Worktree.ID)
}
