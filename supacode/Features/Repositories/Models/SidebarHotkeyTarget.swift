import Foundation

enum SidebarHotkeyTarget: Equatable {
  case repository(
    id: Repository.ID,
    name: String
  )
  case worktree(
    id: Worktree.ID,
    repositoryID: Repository.ID,
    repositoryName: String,
    worktreeName: String
  )

  var title: String {
    switch self {
    case .repository(_, let name):
      return "Repository — \(name)"
    case .worktree(_, _, let repositoryName, let worktreeName):
      return "\(repositoryName) — \(worktreeName)"
    }
  }
}

extension RepositoriesFeature.State {
  func sidebarHotkeyTargets(expandedRepoIDs: Set<Repository.ID>) -> [SidebarHotkeyTarget] {
    let repositoriesByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    var targets: [SidebarHotkeyTarget] = []
    for repositoryID in orderedRepositoryIDs() {
      guard let repository = repositoriesByID[repositoryID] else { continue }
      if expandedRepoIDs.contains(repositoryID) {
        for row in worktreeRows(in: repository) {
          targets.append(
            .worktree(
              id: row.id,
              repositoryID: row.repositoryID,
              repositoryName: repository.name,
              worktreeName: row.name
            )
          )
        }
      } else {
        targets.append(.repository(id: repositoryID, name: repository.name))
      }
    }
    return targets
  }
}
