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
    let restorableAgent: RestorableAgent?

    init(id: UUID?, workingDirectory: String?, restorableAgent: RestorableAgent? = nil) {
      self.id = id
      self.workingDirectory = workingDirectory
      self.restorableAgent = restorableAgent
    }

    private enum CodingKeys: String, CodingKey {
      case id, workingDirectory, restorableAgent
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decodeIfPresent(UUID.self, forKey: .id)
      workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
      // `try?` so a malformed or unrecognized restorableAgent (e.g. an agent
      // rawValue a newer build introduced) drops the field instead of the
      // whole surface leaf.
      restorableAgent =
        (try? container.decodeIfPresent(RestorableAgent.self, forKey: .restorableAgent)) ?? nil
    }
  }

  /// Per-surface intent to resume a coding agent session on next app launch.
  /// Written by hook lifecycle events (`session_start` set, `session_end` /
  /// presence eviction clear) and consumed once during layout restore.
  struct RestorableAgent: Codable, Equatable, Sendable {
    let agent: SkillAgent
    let sessionID: String
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
