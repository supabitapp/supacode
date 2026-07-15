import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// The menu bar's sections: the Pinned and Active rows it hoists (always,
/// regardless of the user's sidebar grouping toggles), then an Unread section
/// for anything unread that neither one already shows. Only row IDs are cached;
/// each row observes its own leaf, exactly like the sidebar.
struct MenuBarSections: Equatable {
  var pinned: [Worktree.ID] = []
  var active: [Worktree.ID] = []
  var unread: [Worktree.ID] = []
  /// Repo tags for the `repo · worktree` subtitle, one per repo contributing a
  /// Pinned, Active, or Unread row. Built by `computeMenuBarSections` rather than
  /// reused from the sidebar so the tags survive when sidebar grouping is off.
  var repositoryTagByID: [Repository.ID: SidebarHighlightRepoTag] = [:]
  /// Any unread row at all, hoisted or not. Drives the status item's dot and
  /// the "Mark Unread Notifications as Read" gate, which must not go dark just
  /// because the only unread row is also Active.
  var hasUnread = false

  var isEmpty: Bool { pinned.isEmpty && active.isEmpty && unread.isEmpty }

  /// Headers and rows flattened into the order the menu renders them.
  var entries: [MenuBarEntry] {
    var entries: [MenuBarEntry] = []
    appendSection(&entries, title: "Pinned", rowIDs: pinned, dotColor: .pinned)
    appendSection(&entries, title: "Active", rowIDs: active, dotColor: .active)
    appendSection(&entries, title: "Unread", rowIDs: unread, dotColor: nil)
    return entries
  }

  private func appendSection(
    _ entries: inout [MenuBarEntry],
    title: String,
    rowIDs: [Worktree.ID],
    dotColor: SidebarStructure.HighlightKind?
  ) {
    guard !rowIDs.isEmpty else { return }
    entries.append(MenuBarEntry(id: .header(title), content: .header(title, dotColor)))
    entries.append(contentsOf: rowIDs.map { MenuBarEntry(id: .row($0), content: .worktree($0)) })
  }
}

/// One line of the menu: a section header or a worktree row.
struct MenuBarEntry: Identifiable, Equatable {
  enum Key: Hashable {
    case header(String)
    case row(Worktree.ID)
  }

  enum Content: Equatable {
    case header(String, SidebarStructure.HighlightKind?)
    case worktree(Worktree.ID)
  }

  let id: Key
  let content: Content
}

extension RepositoriesFeature.State {
  /// Cached on `menuBarSectionsCache`; the menu bar scene reads the cache
  /// rather than walking `sidebarItems` from its body.
  func computeMenuBarSections() -> MenuBarSections {
    // Force the Pinned/Active hoists on so the menu lists them even when the
    // user turned sidebar grouping off.
    let hoists = menuBarForcedHoists()
    var sections = MenuBarSections()
    sections.pinned = hoists.pinned
    sections.active = hoists.active

    let unread = unreadRowIDs()
    sections.hasUnread = !unread.isEmpty
    // The Pinned and Active sections already show their rows; listing them again
    // under Unread would double them up. Dedupe against the menu's own hoist set,
    // not the sidebar's, which is empty when grouping is off.
    sections.unread = unread.filter { !hoists.hoistedSet.contains($0) }

    // Build the subtitle tag for every repo contributing a row. Rebuilt here
    // rather than reused from `sidebarStructure` so the tags survive when the
    // sidebar's grouping projections are empty.
    for rowID in hoists.pinned + hoists.active + sections.unread {
      guard let repositoryID = sidebarItems[id: rowID]?.repositoryID,
        sections.repositoryTagByID[repositoryID] == nil,
        let repository = repositories[id: repositoryID]
      else { continue }
      let section = sidebar.sections[repositoryID]
      sections.repositoryTagByID[repositoryID] = SidebarHighlightRepoTag(
        repoName: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
        repoColor: section?.color,
        hostInfo: repository.host?.displayAuthority
      )
    }
    return sections
  }

  /// Rows carrying unread notifications, in sidebar order. Folders included:
  /// their notifications land on the synthetic row standing in for the folder.
  private func unreadRowIDs() -> [Worktree.ID] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    var orderedIDs = orderedRepositoryIDs()
    let coveredIDs = Set(orderedIDs)
    for repository in repositories where repository.host != nil && !coveredIDs.contains(repository.id) {
      orderedIDs.append(repository.id)
    }

    let archived = archivedWorktreeIDSet
    var rowIDs: [Worktree.ID] = []
    for repositoryID in orderedIDs {
      guard let repository = repositoriesByID[repositoryID] else { continue }
      guard repository.isGitRepository else {
        // A remote folder keys its synthetic row off the host-scoped worktree id,
        // not the local path id, so resolve it the same way the sidebar does.
        let folderID =
          repository.host != nil
          ? repository.worktrees.first?.id
          : Repository.folderWorktreeID(for: repository.rootURL)
        if let folderID, sidebarItems[id: folderID]?.hasUnseenNotifications == true {
          rowIDs.append(folderID)
        }
        continue
      }
      for worktree in orderedWorktrees(in: repository)
      where !archived.contains(worktree.id)
        && sidebarItems[id: worktree.id]?.hasUnseenNotifications == true
      {
        rowIDs.append(worktree.id)
      }
    }
    return rowIDs
  }
}
