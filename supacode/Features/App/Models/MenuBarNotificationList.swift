import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// The menu bar's sections, mirroring the sidebar: the Pinned and Active rows
/// it hoists, then an Unread section for anything unread that neither one
/// already shows. Only row IDs are cached; each row observes its own leaf,
/// exactly like the sidebar does.
struct MenuBarSections: Equatable {
  var pinned: [Worktree.ID] = []
  var active: [Worktree.ID] = []
  var unread: [Worktree.ID] = []
  /// Repo tags for the `repo · worktree` subtitle. `sidebarStructure` only
  /// builds these for repos contributing a highlight row, so unread-only repos
  /// need their own.
  var repositoryTagByID: [Repository.ID: SidebarHighlightRepoTag] = [:]
  /// Any unread row at all, hoisted or not. Drives the status item's dot and
  /// the "Mark All as Read" gate, which must not go dark just because the only
  /// unread row is also Active.
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
    var sections = MenuBarSections(repositoryTagByID: sidebarStructure.repositoryHighlightByID)
    for section in sidebarStructure.sections {
      guard case .highlight(let kind, let rowIDs) = section else { continue }
      switch kind {
      case .pinned: sections.pinned = rowIDs
      case .active: sections.active = rowIDs
      }
    }
    let unread = unreadRowIDs()
    sections.hasUnread = !unread.isEmpty
    // The highlight sections already show their rows; listing them again under
    // Unread would double them up.
    sections.unread = unread.filter { !sidebarStructure.hoistedRowIDs.contains($0) }
    for rowID in sections.unread {
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
        let folderID = Repository.folderWorktreeID(for: repository.rootURL)
        if sidebarItems[id: folderID]?.hasUnseenNotifications == true {
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
