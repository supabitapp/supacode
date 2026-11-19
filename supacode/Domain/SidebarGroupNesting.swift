import Foundation

/// Pure data layer for user-assigned sidebar groups. A row's group is a
/// slash-separated path (`Project 1/Backend`) stored on its sidebar item; the
/// Pinned and Active sections render those paths as nested, collapsible folders
/// using the same `Row` shape as branch nesting.
enum SidebarGroupNesting {
  /// Canonical form of a user-typed group path: components trimmed, empty
  /// components dropped, joined by `/`. `nil` when nothing is left, which means
  /// "no group".
  static func normalized(_ raw: String) -> String? {
    let components =
      raw
      .split(separator: "/")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return components.isEmpty ? nil : components.joined(separator: "/")
  }

  /// Every folder path from the top down: `a/b/c` → `["a", "a/b", "a/b/c"]`.
  static func paths(including path: String) -> [String] {
    var result: [String] = []
    var current = ""
    for component in path.split(separator: "/") {
      current = current.isEmpty ? String(component) : "\(current)/\(component)"
      result.append(current)
    }
    return result
  }

  /// Nests `orderedIDs` under their group folders. A folder appears where its
  /// first row would, and rows keep their incoming order, so the Active
  /// section's priority order survives grouping. Rows under a collapsed folder
  /// are omitted; the folder header still lists them for its indicators.
  static func buildRows(
    orderedIDs: [SidebarItemID],
    groupByID: [SidebarItemID: String],
    collapsedPaths: Set<String>
  ) -> [SidebarBranchNesting.Row] {
    var children: [String: [Child]] = [:]
    var knownFolders: Set<String> = []
    for id in orderedIDs {
      var parent = ""
      for path in groupByID[id].map(paths(including:)) ?? [] {
        if knownFolders.insert(path).inserted {
          children[parent, default: []].append(.folder(path))
        }
        parent = path
      }
      children[parent, default: []].append(.leaf(id))
    }
    var rows: [SidebarBranchNesting.Row] = []
    emit(parent: "", depth: 0, children: children, collapsedPaths: collapsedPaths, into: &rows)
    return rows
  }

  private enum Child {
    case folder(String)
    case leaf(SidebarItemID)
  }

  private static func emit(
    parent: String,
    depth: Int,
    children: [String: [Child]],
    collapsedPaths: Set<String>,
    into rows: inout [SidebarBranchNesting.Row]
  ) {
    for child in children[parent] ?? [] {
      switch child {
      case .leaf(let id):
        rows.append(.leaf(id: id, depth: depth, displayName: nil))
      case .folder(let path):
        let isCollapsed = collapsedPaths.contains(path)
        rows.append(
          .groupHeader(
            prefix: path,
            components: [path.split(separator: "/").last.map(String.init) ?? path],
            depth: depth,
            isCollapsed: isCollapsed,
            leafDescendantIDs: leaves(under: path, children: children)
          )
        )
        if !isCollapsed {
          emit(parent: path, depth: depth + 1, children: children, collapsedPaths: collapsedPaths, into: &rows)
        }
      }
    }
  }

  private static func leaves(under parent: String, children: [String: [Child]]) -> [SidebarItemID] {
    (children[parent] ?? []).flatMap { child -> [SidebarItemID] in
      switch child {
      case .leaf(let id): [id]
      case .folder(let path): leaves(under: path, children: children)
      }
    }
  }
}
