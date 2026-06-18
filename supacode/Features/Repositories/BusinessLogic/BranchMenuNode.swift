import Foundation
import SupacodeSettingsShared

/// Pre-built base-ref menu trees for a repository. Split once when the
/// inventory is populated so the menu render path never rebuilds the trie.
struct BaseRefBranchMenu: Equatable {
  var localBranches: [BranchMenuNode]
  var remotes: [Remote]

  struct Remote: Equatable, Identifiable {
    let name: String
    let branches: [BranchMenuNode]
    var id: String { name }
  }

  /// `hoistedLocalBranch` (the default-branch quick pick) is dropped from the
  /// Local submenu so the same ref can't render and check-mark in two places.
  init(inventory: GitBranchInventory, hoistedLocalBranch: String? = nil) {
    let locals = inventory.localBranches.filter { $0 != hoistedLocalBranch }
    localBranches = BranchMenuNode.build(branches: locals, refPrefix: "")
    remotes = inventory.remotes.map { remote in
      Remote(
        name: remote.name,
        branches: BranchMenuNode.build(branches: remote.branches, refPrefix: "\(remote.name)/")
      )
    }
  }

  /// Every selectable ref across local + remote branches, flattened out of the
  /// display trie in sorted tree order. Backs the searchable base-ref picker (#387).
  func allRefs() -> [String] {
    BranchMenuNode.refs(in: localBranches) + remotes.flatMap { BranchMenuNode.refs(in: $0.branches) }
  }

  /// Refs containing `query` as a case/diacritic-insensitive substring, in tree
  /// order. A blank query returns every ref. Matching the full ref (e.g.
  /// `origin/feature/jira-1234/foo`) lets the user type any fragment — remote,
  /// namespace, or leaf — instead of drilling submenus.
  func refs(matching query: String) -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = allRefs()
    guard !trimmed.isEmpty else { return all }
    return all.filter { $0.localizedCaseInsensitiveContains(trimmed) }
  }
}

/// A node in the base-ref selection menu. Branch names are split on `/`
/// so deep namespaces (`origin/sbertix/feature/foo`) nest into submenus
/// instead of overwhelming a single flat list.
struct BranchMenuNode: Equatable, Identifiable {
  let id: String
  let name: String
  /// Full ref to create from when this node is a selectable branch; `nil`
  /// for pure grouping segments.
  let ref: String?
  let children: [BranchMenuNode]

  /// Depth-first selectable refs (nodes with a non-nil `ref`), in sorted tree
  /// order. A namespace segment that is itself a branch contributes its own ref
  /// before its children's.
  static func refs(in nodes: [BranchMenuNode]) -> [String] {
    nodes.flatMap { node in (node.ref.map { [$0] } ?? []) + refs(in: node.children) }
  }

  /// Builds a sorted node tree from full branch names. `refPrefix` is
  /// prepended to each branch to form its ref (e.g. `origin/` for a remote).
  static func build(branches: [String], refPrefix: String) -> [BranchMenuNode] {
    let root = TrieNode()
    for branch in branches {
      let segments = branch.split(separator: "/").map(String.init)
      guard !segments.isEmpty else { continue }
      var node = root
      for segment in segments {
        let child = node.children[segment] ?? TrieNode()
        node.children[segment] = child
        node = child
      }
      node.branch = branch
    }
    return root.sortedChildren(pathPrefix: "", refPrefix: refPrefix)
  }

  private final class TrieNode {
    var children: [String: TrieNode] = [:]
    var branch: String?

    func sortedChildren(pathPrefix: String, refPrefix: String) -> [BranchMenuNode] {
      children
        .map { segment, child in
          let path = pathPrefix.isEmpty ? segment : "\(pathPrefix)/\(segment)"
          return BranchMenuNode(
            id: refPrefix + path,
            name: segment,
            ref: child.branch.map { refPrefix + $0 },
            children: child.sortedChildren(pathPrefix: path, refPrefix: refPrefix)
          )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
  }
}
