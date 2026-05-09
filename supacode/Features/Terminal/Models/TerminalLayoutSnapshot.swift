import Foundation
import SupacodeSettingsShared

struct TerminalLayoutSnapshot: Codable, Equatable, Sendable {
  let tabs: [TabSnapshot]
  let selectedTabIndex: Int

  struct TabSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let title: String
    let customTitle: String?
    let icon: String?
    let tintColor: RepositoryColor?
    let layout: LayoutNode
    let focusedLeafIndex: Int

    init(
      id: UUID?,
      title: String,
      customTitle: String?,
      icon: String?,
      tintColor: RepositoryColor?,
      layout: LayoutNode,
      focusedLeafIndex: Int
    ) {
      self.id = id
      self.title = title
      self.customTitle = customTitle
      self.icon = icon
      self.tintColor = tintColor
      self.layout = layout
      self.focusedLeafIndex = focusedLeafIndex
    }

    private enum CodingKeys: String, CodingKey {
      case id, title, customTitle, icon, tintColor, layout, focusedLeafIndex
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decodeIfPresent(UUID.self, forKey: .id)
      title = try container.decode(String.self, forKey: .title)
      customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
      icon = try container.decodeIfPresent(String.self, forKey: .icon)
      // `try?` so a tint value the running build doesn't recognize (e.g. hex
      // from a newer build read by an older one) drops the field, not the tab.
      tintColor = (try? container.decodeIfPresent(RepositoryColor.self, forKey: .tintColor)) ?? nil
      layout = try container.decode(LayoutNode.self, forKey: .layout)
      focusedLeafIndex = try container.decode(Int.self, forKey: .focusedLeafIndex)
    }
  }

  indirect enum LayoutNode: Codable, Equatable, Sendable {
    case leaf(SurfaceSnapshot)
    case split(SplitSnapshot)
  }

  struct SplitSnapshot: Codable, Equatable, Sendable {
    let direction: SplitDirection
    let ratio: Double
    let left: LayoutNode
    let right: LayoutNode
  }

  struct SurfaceSnapshot: Codable, Equatable, Sendable {
    let id: UUID?
    let workingDirectory: String?
  }

}

extension TerminalLayoutSnapshot.LayoutNode {
  /// The leftmost leaf in the subtree.
  var firstLeaf: TerminalLayoutSnapshot.SurfaceSnapshot {
    switch self {
    case .leaf(let surface):
      return surface
    case .split(let split):
      return split.left.firstLeaf
    }
  }

  /// The number of leaves in the subtree.
  var leafCount: Int {
    switch self {
    case .leaf:
      return 1
    case .split(let split):
      return split.left.leafCount + split.right.leafCount
    }
  }
}
