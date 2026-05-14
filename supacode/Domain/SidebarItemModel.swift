import Foundation
import SwiftUI

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

  /// `nil` for the main worktree so view sites can resolve to localized copy.
  var sidebarDisplayName: String? {
    guard !isMainWorktree else { return nil }
    if id.contains("/") {
      let pathName = URL(fileURLWithPath: id).lastPathComponent
      guard pathName.isEmpty else { return pathName }
    }
    if !detail.isEmpty, detail != "." {
      let detailName = URL(fileURLWithPath: detail).lastPathComponent
      guard detailName.isEmpty || detailName == "." else { return detailName }
    }
    return name
  }

  var accent: WorktreeAccent {
    if isMainWorktree { return .main }
    if isPinned { return .pinned }
    return .default
  }
}

enum WorktreeAccent: Hashable, Sendable {
  case `default`
  case main
  case pinned

  func shapeStyle(emphasized: Bool) -> AnyShapeStyle {
    guard !emphasized else { return AnyShapeStyle(.secondary) }
    return switch self {
    case .main: AnyShapeStyle(.yellow)
    case .pinned: AnyShapeStyle(.orange)
    case .default: AnyShapeStyle(.tertiary)
    }
  }
}
