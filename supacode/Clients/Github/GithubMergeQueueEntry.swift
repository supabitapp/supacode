import Foundation

nonisolated struct GithubMergeQueueEntry: Decodable, Equatable, Hashable {
  // GitHub's queue `position` is 1-based: the first entry reports position 1, so it renders as-is.
  let position: Int
  let estimatedTimeToMerge: Int?
  let state: String?
}
