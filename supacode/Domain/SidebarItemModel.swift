import Foundation

struct SidebarItemModel: Identifiable, Hashable {
  enum Kind: Hashable {
    case git
    case folder
  }

  enum Status: Hashable {
    case idle
    case pending
    case archiving
    case deleting(inTerminal: Bool)
  }

  let id: String
  let repositoryID: Repository.ID
  let kind: Kind
  let name: String
  let detail: String
  let info: WorktreeInfoEntry?
  let isPinned: Bool
  let isMainWorktree: Bool
  let status: Status

  var isFolder: Bool { kind == .folder }
  var isPending: Bool { status == .pending }
  var isArchiving: Bool { status == .archiving }
  var isDeleting: Bool { if case .deleting = status { true } else { false } }
  var isLoading: Bool { status != .idle }
  var isRemovable: Bool { status == .idle }
}
