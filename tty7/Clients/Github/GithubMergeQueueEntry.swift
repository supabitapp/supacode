import Foundation

nonisolated struct GithubMergeQueueEntry: Decodable, Equatable, Hashable {
  // GitHub's queue `position` is observed to be 0-based; `displayPosition` renders it 1-based.
  let position: Int
  let estimatedTimeToMerge: Int?
  let state: String?

  var displayPosition: Int {
    position + 1
  }
}
