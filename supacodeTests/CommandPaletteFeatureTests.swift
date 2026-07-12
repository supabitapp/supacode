import ComposableArchitecture
import CustomDump
import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct CommandPaletteFeatureTests {
  @Test func commandPaletteItems_onlyGlobalWhenEmpty() {
    let items = CommandPaletteFeature.commandPaletteItems(from: RepositoriesFeature.State())
    var expectedIDs = [
      "global.check-for-updates",
      "global.open-settings",
      "global.open-repository",
      "global.add-remote-repository",
      "global.new-worktree",
      "global.refresh-worktrees",
      "global.view-archived-worktrees",
    ]
    #if DEBUG
      expectedIDs.append(contentsOf: [
        "debug.toast.inProgress",
        "debug.toast.success",
      ])
    #endif
    expectNoDifference(items.map(\.id), expectedIDs)
  }

  @Test func worktreeSwitcherItems_skipsPendingAndDeletingWorktrees() {
    let rootPath = "/tmp/repo"
    let keep = makeWorktree(id: "\(rootPath)/wt-keep", name: "keep", repoRoot: rootPath)
    let deleting = makeWorktree(
      id: "\(rootPath)/wt-delete",
      name: "delete",
      repoRoot: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [keep, deleting])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.sidebarItems[id: deleting.id]?.lifecycle = .deleting
    state.pendingWorktrees = [
      PendingWorktree(
        id: WorktreeID("\(rootPath)/wt-pending"),
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(
          stage: .creatingWorktree,
          worktreeName: "pending",
          baseRef: "origin/main",
          copyIgnored: false,
          copyUntracked: false
        )
      )
    ]
    state.reconcileSidebarForTesting()

    let items = CommandPaletteFeature.worktreeSwitcherItems(from: state)
    let ids = items.map(\.id)
    #expect(ids.contains("worktree.\(keep.id).select"))
    #expect(ids.contains { $0.contains(deleting.id.rawValue) } == false)
    #expect(ids.contains { $0.contains("wt-pending") } == false)
  }

  @Test func commandPaletteItems_includeGhosttyCommandsWhenWorktreeSelected() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      ghosttyCommands: [
        GhosttyCommand(
          title: "Focus Split Right",
          description: "Focus the split to the right.",
          action: "goto_split:right",
          actionKey: "goto_split"
        )
      ]
    )

    let ghosttyItem = items.first {
      if case .ghosttyCommand(let action) = $0.kind {
        return action == "goto_split:right"
      }
      return false
    }

    #expect(ghosttyItem?.title == "Focus Split Right")
    #expect(ghosttyItem?.subtitle == "Focus the split to the right.")
  }

  @Test func commandPaletteItems_includesRenameBranchOnlyForSelectedWorktree() {
    let rootPath = "/tmp/repo-rename"
    let main = makeWorktree(id: "\(rootPath)/main", name: "main", repoRoot: rootPath)
    let feature = makeWorktree(
      id: "\(rootPath)/feature",
      name: "feature/old",
      repoRoot: rootPath
    )
    let other = makeWorktree(
      id: "\(rootPath)/other",
      name: "other",
      repoRoot: rootPath
    )
    let repository = makeRepository(
      rootPath: rootPath,
      name: "Repo",
      worktrees: [main, feature, other]
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(feature.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let renameItems = items.filter {
      if case .renameBranch = $0.kind { return true }
      return false
    }
    #expect(renameItems.count == 1)
    #expect(renameItems.first?.id == "worktree.\(feature.id).rename-branch")
    #expect(renameItems.first?.title == "Rename Branch")
    #expect(renameItems.first?.subtitle == "Repo · feature/old")
  }

  @Test func commandPaletteItems_omitsRenameBranchForDetachedHeadSelection() {
    let rootPath = "/tmp/repo-rename-detached"
    let main = makeWorktree(id: rootPath, name: "main", repoRoot: rootPath)
    let detached = Worktree(
      id: WorktreeID("\(rootPath)/dt"),
      name: "dt",
      detail: "dt",
      workingDirectory: URL(fileURLWithPath: "\(rootPath)/dt"),
      repositoryRootURL: URL(fileURLWithPath: rootPath),
      isAttached: false
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [main, detached])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(detached.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(
      items.contains {
        if case .renameBranch = $0.kind { return true }
        return false
      } == false
    )
  }

  @Test func commandPaletteItems_includesRenameBranchForMainWorktreeSelection() {
    let rootPath = "/tmp/repo-rename-main"
    // The main worktree is identified by `workingDirectory == repositoryRootURL`,
    // so the row must live at the repo root for `isMainWorktree` to be true.
    let main = makeWorktree(id: rootPath, name: "main", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [main])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(main.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(
      items.contains {
        if case .renameBranch = $0.kind { return true }
        return false
      }
    )
  }

  @Test func commandPaletteItems_omitGhosttyCommandsWithoutSelectedWorktree() {
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(),
      ghosttyCommands: [
        GhosttyCommand(
          title: "Focus Split Right",
          description: "",
          action: "goto_split:right",
          actionKey: "goto_split"
        )
      ]
    )

    #expect(
      items.contains {
        if case .ghosttyCommand = $0.kind {
          return true
        }
        return false
      } == false
    )
  }

  @Test func emptyQueryHidesGhosttyCommands() {
    let ghosttyItem = CommandPaletteItem(
      id: "ghostty.goto_split:right|Focus Split Right",
      title: "Focus Split Right",
      subtitle: nil,
      kind: .ghosttyCommand("goto_split:right")
    )
    let prAction = CommandPaletteItem(
      id: "pr.open",
      title: "Open PR on GitHub",
      subtitle: "PR title",
      kind: .openPullRequest("wt-1"),
      priorityTier: 2
    )

    let result = CommandPaletteFeature.filterItems(
      items: [ghosttyItem, prAction],
      query: ""
    )

    #expect(!result.contains { $0.id == ghosttyItem.id })
    #expect(result.contains { $0.id == prAction.id })
  }

  @Test func commandPaletteItems_omitsSubActionsForMainWorktree() {
    let rootPath = "/tmp/repo"
    let main = makeWorktree(
      id: rootPath,
      name: "repo",
      detail: "main",
      repoRoot: rootPath,
      workingDirectory: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [main])
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(reconciledRepositories: [repository])
    )

    #expect(
      items.contains {
        if case .removeWorktree = $0.kind {
          return true
        }
        return false
      } == false
    )
    #expect(
      items.contains {
        if case .archiveWorktree = $0.kind {
          return true
        }
        return false
      } == false
    )
    // The commands palette lists no worktree-navigation rows (that is the ⌘P
    // switcher's job now), only actions.
    #expect(
      items.filter {
        if case .worktreeSelect = $0.kind {
          return true
        }
        return false
      }.count == 0
    )
  }

  @Test func commandPaletteItems_omitsSubActionsForNonMainWorktree() {
    let rootPath = "/tmp/repo"
    let main = makeWorktree(
      id: rootPath,
      name: "repo",
      detail: "main",
      repoRoot: rootPath,
      workingDirectory: rootPath
    )
    let feature = makeWorktree(
      id: "\(rootPath)/wt-feature",
      name: "feature",
      detail: "feature",
      repoRoot: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [main, feature])
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(reconciledRepositories: [repository])
    )

    #expect(
      items.contains {
        if case .removeWorktree = $0.kind {
          return true
        }
        return false
      } == false
    )
    #expect(
      items.contains {
        if case .archiveWorktree = $0.kind {
          return true
        }
        return false
      } == false
    )
  }

  @Test func worktreeSwitcherItems_keepsFullWorktreeName() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(
      id: "\(rootPath)/wt-path",
      name: "khoi/cache",
      detail: "main",
      repoRoot: rootPath
    )
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    let items = CommandPaletteFeature.worktreeSwitcherItems(
      from: RepositoriesFeature.State(reconciledRepositories: [repository])
    )
    let selectItem = items.first {
      if case .worktreeSelect(let id) = $0.kind {
        return id == worktree.id
      }
      return false
    }
    // The worktree name is the title verbatim (a `/` in the branch is not truncated).
    #expect(selectItem?.title == "khoi/cache")
    #expect(selectItem?.subtitle == "Repo")
  }

  @Test func worktreeSwitcherItems_respectsRowOrderWithinRepository() {
    let rootPath = "/tmp/repo"
    let main = makeWorktree(
      id: rootPath,
      name: "repo",
      detail: "main",
      repoRoot: rootPath,
      workingDirectory: rootPath
    )
    let pinned = makeWorktree(
      id: "\(rootPath)/wt-pinned",
      name: "pinned",
      detail: "pinned",
      repoRoot: rootPath
    )
    let unpinned = makeWorktree(
      id: "\(rootPath)/wt-unpinned",
      name: "unpinned",
      detail: "unpinned",
      repoRoot: rootPath
    )
    let repository = makeRepository(
      rootPath: rootPath, name: "Repo",
      worktrees: [
        main,
        pinned,
        unpinned,
      ])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [
          .pinned: .init(items: [pinned.id: .init()]),
          .unpinned: .init(items: [unpinned.id: .init()]),
        ]
      )
    }

    let items = CommandPaletteFeature.worktreeSwitcherItems(from: state)
    let selectIDs = items.compactMap { item in
      if case .worktreeSelect(let id) = item.kind {
        return id
      }
      return nil
    }
    expectNoDifference(selectIDs, [main.id, pinned.id, unpinned.id])
  }

  @Test func worktreeSwitcherItems_respectsRepositoryOrder() {
    let repoAPath = "/tmp/repo-a"
    let repoBPath = "/tmp/repo-b"
    let mainA = makeWorktree(
      id: repoAPath,
      name: "repo-a",
      detail: "main",
      repoRoot: repoAPath,
      workingDirectory: repoAPath
    )
    let mainB = makeWorktree(
      id: repoBPath,
      name: "repo-b",
      detail: "main",
      repoRoot: repoBPath,
      workingDirectory: repoBPath
    )
    let repoA = makeRepository(rootPath: repoAPath, name: "Repo A", worktrees: [mainA])
    let repoB = makeRepository(rootPath: repoBPath, name: "Repo B", worktrees: [mainB])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])
    state.repositoryRoots = [repoB.rootURL, repoA.rootURL]

    let items = CommandPaletteFeature.worktreeSwitcherItems(from: state)
    let selectIDs = items.compactMap { item in
      if case .worktreeSelect(let id) = item.kind {
        return id
      }
      return nil
    }
    expectNoDifference(selectIDs, [mainB.id, mainA.id])
  }

  @Test func showsGlobalItemsWhenQueryEmpty() {
    let openSettings = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let newWorktree = CommandPaletteItem(
      id: "global.new-worktree",
      title: "New Worktree",
      subtitle: nil,
      kind: .newWorktree
    )
    let selectFox = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: "main",
      kind: .worktreeSelect("wt-fox")
    )
    let archiveFox = CommandPaletteItem(
      id: "worktree.fox.archive",
      title: "Repo / fox",
      subtitle: "Archive Worktree - main",
      kind: .archiveWorktree("wt-fox", "repo-fox")
    )
    let removeFox = CommandPaletteItem(
      id: "worktree.fox.remove",
      title: "Repo / fox",
      subtitle: "Remove Worktree - main",
      kind: .removeWorktree("wt-fox", "repo-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(
        items: [openSettings, newWorktree, selectFox, archiveFox, removeFox],
        query: ""
      ),
      []
    )
  }

  @Test func queryKeepsSelectionWhenEmpty() async {
    var state = CommandPaletteFeature.State()
    state.query = "fox"
    state.selectedIndex = 1
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }

    await store.send(.binding(.set(\.query, ""))) {
      $0.query = ""
      $0.selectedIndex = 1
    }
  }

  @Test func queryRanksByFuzzyScoreAcrossAllItems() {
    let openSettings = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let selectSettings = CommandPaletteItem(
      id: "worktree.settings.select",
      title: "Repo / settings",
      subtitle: "main",
      kind: .worktreeSelect("wt-settings")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [selectSettings, openSettings], query: "set"),
      [selectSettings, openSettings]
    )
  }

  @Test func fuzzyRanksPrefixAndShorterLabelFirst() {
    let short = CommandPaletteItem(
      id: "worktree.set.select",
      title: "Set",
      subtitle: nil,
      kind: .worktreeSelect("wt-set")
    )
    let long = CommandPaletteItem(
      id: "worktree.settings.select",
      title: "Settings",
      subtitle: nil,
      kind: .worktreeSelect("wt-settings")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [long, short], query: "set"),
      [short, long]
    )
  }

  @Test func fuzzyMatchesSubtitleWhenLabelDoesNot() {
    let item = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: "main",
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [item], query: "main"),
      [item]
    )
  }

  @Test func fuzzyMatchesMultiplePieces() {
    let item = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: "main",
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [item], query: "repo main"),
      [item]
    )
  }

  @Test func directSubtitleMatchOutranksScatteredTitleMatch() {
    // The worktree-title + repo-subtitle split must not let a scattered fuzzy hit
    // on the worktree name bury a clean direct hit on the repo name. Query "main"
    // scatter-matches the title "mountain-trail" but exactly matches the repo
    // subtitle "main" of the other row — the direct repo hit must win.
    let scatteredTitle = CommandPaletteItem(
      id: "worktree.mountain",
      title: "mountain-trail",
      subtitle: "zzz",
      kind: .worktreeSelect("wt-mountain")
    )
    let directSubtitle = CommandPaletteItem(
      id: "worktree.feature",
      title: "feature-x",
      subtitle: "main",
      kind: .worktreeSelect("wt-feature")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [scatteredTitle, directSubtitle], query: "main"),
      [directSubtitle, scatteredTitle]
    )
  }

  @Test func contiguousSubstringOutranksScatteredSubsequence() {
    // A contiguous substring hit is a "direct" match and must beat a scattered
    // subsequence hit, even when the scattered one lands on separators/word
    // starts whose per-character bonuses would otherwise push it ahead.
    let scattered = CommandPaletteItem(
      id: "worktree.scattered",
      title: "a-zzz-b",
      subtitle: nil,
      kind: .worktreeSelect("wt-scattered")
    )
    let substring = CommandPaletteItem(
      id: "worktree.substring",
      title: "xab",
      subtitle: nil,
      kind: .worktreeSelect("wt-substring")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [scattered, substring], query: "ab"),
      [substring, scattered]
    )
  }

  @Test func commandPaletteDraftActionRanksFirst() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-draft", name: "draft", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.setWorktreeInfoForTesting(id: worktree.id, pullRequest: makePullRequest(isDraft: true))

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Mark PR Ready for Review")
  }

  @Test func commandPaletteFailingActionRanksFirst() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-failing", name: "failing", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    let failingCheck = GithubPullRequestStatusCheck(
      detailsUrl: "https://example.com/check/1",
      status: "COMPLETED",
      conclusion: "FAILURE",
      state: nil
    )
    state.setWorktreeInfoForTesting(
      id: worktree.id, pullRequest: makePullRequest(checks: [failingCheck])
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Copy failing job URL")
  }

  @Test func commandPaletteFailingActionFallsBackToLogsWhenCheckURLMissing() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-failing", name: "failing", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    let failingCheck = GithubPullRequestStatusCheck(
      status: "COMPLETED",
      conclusion: "FAILURE",
      state: nil
    )
    state.setWorktreeInfoForTesting(
      id: worktree.id, pullRequest: makePullRequest(checks: [failingCheck])
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Copy CI Failure Logs")
  }

  @Test func commandPaletteMergeActionRanksFirstWhenMergeable() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-merge", name: "merge", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.setWorktreeInfoForTesting(
      id: worktree.id,
      pullRequest: makePullRequest(mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let ordered = CommandPaletteFeature.filterItems(items: items, query: "")
    #expect(ordered.first?.title == "Merge PR")
  }

  @Test func commandPaletteShowsCloseActionForOpenPullRequest() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-close", name: "close", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.setWorktreeInfoForTesting(id: worktree.id, pullRequest: makePullRequest(state: "OPEN"))

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    let closeItem = items.first(where: { $0.title == "Close PR" })
    #expect(closeItem != nil)
    #expect(closeItem?.subtitle == "PR")
    if case .some(.closePullRequest(let closeWorktreeID)) = closeItem?.kind {
      #expect(closeWorktreeID == worktree.id)
    } else {
      Issue.record("Expected close pull request command palette action")
    }
  }

  @Test func commandPaletteDoesNotShowCloseActionForMergedPullRequest() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-merged", name: "merged", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.setWorktreeInfoForTesting(id: worktree.id, pullRequest: makePullRequest(state: "MERGED"))

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(!items.contains(where: { $0.title == "Close PR" }))
  }

  @Test func commandPaletteDoesNotShowMergeActionWhenBlocked() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: "\(rootPath)/wt-blocked", name: "blocked", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)
    state.setWorktreeInfoForTesting(
      id: worktree.id,
      pullRequest: makePullRequest(mergeable: "UNKNOWN", mergeStateStatus: "BLOCKED")
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: state)
    #expect(!items.contains(where: { $0.title == "Merge PR" }))
  }

  @Test func recencyBreaksFuzzyTiesWithinGroup() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let recent = CommandPaletteItem(
      id: "global.recent",
      title: "Open",
      subtitle: nil,
      kind: .openRepository
    )
    let older = CommandPaletteItem(
      id: "global.older",
      title: "Open",
      subtitle: nil,
      kind: .openSettings
    )
    let recency: [CommandPaletteItem.ID: TimeInterval] = [
      recent.id: now.timeIntervalSince1970 - 1 * 86_400,
      older.id: now.timeIntervalSince1970 - 10 * 86_400,
    ]

    expectNoDifference(
      CommandPaletteFeature.filterItems(
        items: [older, recent],
        query: "open",
        recencyByID: recency,
        now: now
      ),
      [recent, older]
    )
  }

  @Test func supacodeItemsBeatGhosttyItemsWhenScoresTie() {
    let supacodeItem = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let ghosttyItem = CommandPaletteItem(
      id: "ghostty.open-settings|Open Settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .ghosttyCommand("open_settings"),
      priorityTier: CommandPaletteItem.defaultPriorityTier + 100
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(
        items: [ghosttyItem, supacodeItem],
        query: "open settings"
      ),
      [supacodeItem, ghosttyItem]
    )
  }

  // MARK: - Unified Ranking Tests

  @Test func worktreeOutranksGlobalWhenBetterMatch() {
    let checkForUpdates = CommandPaletteItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [checkForUpdates, worktreeFox], query: "fox"),
      [worktreeFox]
    )
  }

  @Test func worktreeExactPrefixOutranksGlobalSubstringMatch() {
    let openSettings = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeOpen = CommandPaletteItem(
      id: "worktree.open.select",
      title: "open",
      subtitle: nil,
      kind: .worktreeSelect("wt-open")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openSettings, worktreeOpen],
      query: "open"
    )
    #expect(result.first?.id == worktreeOpen.id)
  }

  @Test func globalAndWorktreeItemsInterleavedByScore() {
    let openRepo = CommandPaletteItem(
      id: "global.open-repository",
      title: "Open Repository",
      subtitle: nil,
      kind: .openRepository
    )
    let worktreeRepo = CommandPaletteItem(
      id: "worktree.repo.select",
      title: "repo",
      subtitle: nil,
      kind: .worktreeSelect("wt-repo")
    )
    let refreshWorktrees = CommandPaletteItem(
      id: "global.refresh-worktrees",
      title: "Refresh Worktrees",
      subtitle: nil,
      kind: .refreshWorktrees
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openRepo, worktreeRepo, refreshWorktrees],
      query: "repo"
    )

    #expect(result.contains { $0.id == worktreeRepo.id })
    #expect(result.contains { $0.id == openRepo.id })
    #expect(!result.contains { $0.id == refreshWorktrees.id })
  }

  @Test func nonMatchingItemsExcludedRegardlessOfType() {
    let checkForUpdates = CommandPaletteItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    expectNoDifference(
      CommandPaletteFeature.filterItems(items: [checkForUpdates, worktreeFox], query: "zzz"),
      []
    )
  }

  @Test func multipleWorktreesCanAppearBeforeGlobalItems() {
    let openSettings = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeAlpha = CommandPaletteItem(
      id: "worktree.alpha.select",
      title: "set",
      subtitle: nil,
      kind: .worktreeSelect("wt-alpha")
    )
    let worktreeBeta = CommandPaletteItem(
      id: "worktree.beta.select",
      title: "sett",
      subtitle: nil,
      kind: .worktreeSelect("wt-beta")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [openSettings, worktreeAlpha, worktreeBeta],
      query: "set"
    )

    #expect(result.count == 3)
    #expect(result[0].id == worktreeAlpha.id)
    #expect(result[1].id == worktreeBeta.id)
  }

  @Test func priorityTierBreaksTiesAcrossItemTypes() {
    let prAction = CommandPaletteItem(
      id: "pr.merge",
      title: "Merge PR",
      subtitle: "Ready",
      kind: .mergePullRequest("wt-1"),
      priorityTier: 0
    )
    let worktreeMerge = CommandPaletteItem(
      id: "worktree.merge.select",
      title: "Merge",
      subtitle: nil,
      kind: .worktreeSelect("wt-merge")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [worktreeMerge, prAction],
      query: "merge"
    )

    #expect(result.count == 2)
    let prIndex = result.firstIndex { $0.id == prAction.id }!
    let wtIndex = result.firstIndex { $0.id == worktreeMerge.id }!
    #expect(wtIndex < prIndex)
  }

  @Test func recencyBreaksTiesAcrossItemTypes() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let globalItem = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeItem = CommandPaletteItem(
      id: "worktree.settings.select",
      title: "Repo / settings",
      subtitle: nil,
      kind: .worktreeSelect("wt-settings")
    )
    let recency: [CommandPaletteItem.ID: TimeInterval] = [
      worktreeItem.id: now.timeIntervalSince1970 - 1 * 86_400,
      globalItem.id: now.timeIntervalSince1970 - 20 * 86_400,
    ]

    let result = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "settings",
      recencyByID: recency,
      now: now
    )

    #expect(result.first?.id == worktreeItem.id)
  }

  @Test func worktreeWithLabelMatchOutranksGlobalWithDescriptionMatch() {
    let globalItem = CommandPaletteItem(
      id: "global.pr.open",
      title: "Open PR on GitHub",
      subtitle: "deploy-fixes",
      kind: .openPullRequest("wt-1")
    )
    let worktreeItem = CommandPaletteItem(
      id: "worktree.deploy.select",
      title: "Repo / deploy-fixes",
      subtitle: nil,
      kind: .worktreeSelect("wt-deploy")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "deploy"
    )

    #expect(result.first?.id == worktreeItem.id)
  }

  @Test func shorterWorktreeLabelWinsOverLongerGlobalLabel() {
    let globalItem = CommandPaletteItem(
      id: "global.new-worktree",
      title: "New Worktree",
      subtitle: nil,
      kind: .newWorktree
    )
    let worktreeItem = CommandPaletteItem(
      id: "worktree.new.select",
      title: "new",
      subtitle: nil,
      kind: .worktreeSelect("wt-new")
    )

    let result = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "new"
    )

    #expect(result.first?.id == worktreeItem.id)
  }

  @Test func emptyQueryStillHidesRootActionsAndWorktrees() {
    let checkForUpdates = CommandPaletteItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )
    let prAction = CommandPaletteItem(
      id: "pr.open",
      title: "Open PR on GitHub",
      subtitle: "PR title",
      kind: .openPullRequest("wt-1"),
      priorityTier: 2
    )

    let result = CommandPaletteFeature.filterItems(
      items: [checkForUpdates, worktreeFox, prAction],
      query: ""
    )

    #expect(!result.contains { $0.id == checkForUpdates.id })
    #expect(!result.contains { $0.id == worktreeFox.id })
    #expect(result.contains { $0.id == prAction.id })
  }

  @Test func whitespaceOnlyQueryTreatedAsEmpty() {
    let checkForUpdates = CommandPaletteItem(
      id: "global.check-for-updates",
      title: "Check for Updates",
      subtitle: nil,
      kind: .checkForUpdates
    )
    let worktreeFox = CommandPaletteItem(
      id: "worktree.fox.select",
      title: "Repo / fox",
      subtitle: nil,
      kind: .worktreeSelect("wt-fox")
    )

    let emptyResult = CommandPaletteFeature.filterItems(
      items: [checkForUpdates, worktreeFox],
      query: ""
    )
    let whitespaceResult = CommandPaletteFeature.filterItems(
      items: [checkForUpdates, worktreeFox],
      query: "   "
    )

    expectNoDifference(emptyResult, whitespaceResult)
  }

  @Test func inputOrderDoesNotAffectScoreBasedRanking() {
    let globalItem = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    let worktreeItem = CommandPaletteItem(
      id: "worktree.open.select",
      title: "open",
      subtitle: nil,
      kind: .worktreeSelect("wt-open")
    )

    let resultAB = CommandPaletteFeature.filterItems(
      items: [globalItem, worktreeItem],
      query: "open"
    )
    let resultBA = CommandPaletteFeature.filterItems(
      items: [worktreeItem, globalItem],
      query: "open"
    )

    #expect(resultAB.first?.id == resultBA.first?.id)
  }

  @Test func activateDispatchesDelegateAndUpdatesRecency() async {
    var state = CommandPaletteFeature.State()
    state.isPresented = true
    state.query = "bear"
    state.selectedIndex = 1
    let item = CommandPaletteItem(
      id: "global.open-repository",
      title: "Open Repository",
      subtitle: nil,
      kind: .openRepository
    )
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }
    let now = Date(timeIntervalSince1970: 1_234_567)
    store.dependencies.date = .constant(now)

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.query = ""
      $0.selectedIndex = nil
      $0.recencyByItemID[item.id] = now.timeIntervalSince1970
    }
    await store.receive(.delegate(.openRepository))
  }

  @Test func activateGhosttyCommandDispatchesDelegate() async {
    let now = Date(timeIntervalSince1970: 7_654_321)
    let item = CommandPaletteItem(
      id: "ghostty.goto_split:right|Focus Split Right",
      title: "Focus Split Right",
      subtitle: nil,
      kind: .ghosttyCommand("goto_split:right")
    )
    var state = CommandPaletteFeature.State()
    state.isPresented = true
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }
    store.dependencies.date = .constant(now)

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.query = ""
      $0.selectedIndex = nil
      $0.recencyByItemID[item.id] = now.timeIntervalSince1970
    }
    await store.receive(.delegate(.ghosttyCommand("goto_split:right")))
  }

  @Test func updateSelection_usesDefaultIndexWhenNoSelection() async {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }

    // The project switcher hands a defaultIndex of 1 to skip its own
    // current-project row; with no prior selection the cursor lands there.
    await store.send(.updateSelection(itemsCount: 3, defaultIndex: 1)) {
      $0.selectedIndex = 1
    }
  }

  @Test func updateSelection_clampsDefaultIndexToLastRow() async {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }

    // A defaultIndex past the end (e.g. a stale switcher list shrank to one
    // row) clamps to the last valid index rather than overrunning.
    await store.send(.updateSelection(itemsCount: 1, defaultIndex: 1)) {
      $0.selectedIndex = 0
    }
  }

  @Test func updateSelection_keepsExistingSelectionOverDefault() async {
    var state = CommandPaletteFeature.State()
    state.selectedIndex = 0
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }

    // An in-bounds existing selection wins; defaultIndex only seeds a nil
    // selection so arrow-key navigation isn't yanked back on every refresh.
    await store.send(.updateSelection(itemsCount: 3, defaultIndex: 1))
  }

  @Test func resetSelection_usesDefaultIndex() async {
    var state = CommandPaletteFeature.State()
    state.selectedIndex = 2
    let store = TestStore(initialState: state) {
      CommandPaletteFeature()
    }

    // resetSelection (fired on query change) snaps straight to defaultIndex.
    await store.send(.resetSelection(itemsCount: 3, defaultIndex: 1)) {
      $0.selectedIndex = 1
    }
  }

  // MARK: - Script items.

  @Test func commandPaletteItems_includesRunItemsForConfiguredScripts() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)

    let runDef = ScriptDefinition(kind: .run, command: "npm run dev")
    let testDef = ScriptDefinition(kind: .test, command: "npm test")

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      scripts: [runDef, testDef]
    )

    let runItem = items.first { $0.id == "script.\(runDef.id).run" }
    let testItem = items.first { $0.id == "script.\(testDef.id).run" }
    #expect(runItem?.title == "Run: Run")
    #expect(testItem?.title == "Run: Test")
  }

  @Test func commandPaletteItems_showsStopForRunningScripts() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)

    let definition = ScriptDefinition(kind: .run, command: "npm run dev")

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      scripts: [definition],
      runningScriptIDs: [definition.id]
    )

    let stopItem = items.first { $0.id == "script.\(definition.id).stop" }
    #expect(stopItem?.title == "Stop: Run")
    #expect(stopItem?.priorityTier == 0)
    // No run item should exist for a running script.
    let runItem = items.first { $0.id == "script.\(definition.id).run" }
    #expect(runItem == nil)
  }

  @Test func commandPaletteItems_surfacesEmptyCommandScriptsAsConfigure() {
    let rootPath = "/tmp/repo"
    let worktree = makeWorktree(id: rootPath, name: "repo", repoRoot: rootPath)
    let repository = makeRepository(rootPath: rootPath, name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.selection = .worktree(worktree.id)

    let emptyDef = ScriptDefinition(kind: .run, command: "  ")
    let validDef = ScriptDefinition(kind: .test, command: "npm test")

    let items = CommandPaletteFeature.commandPaletteItems(
      from: state,
      scripts: [emptyDef, validDef]
    )

    let emptyItem = items.first { $0.id == "script.\(emptyDef.id).run" }
    #expect(emptyItem != nil)
    #expect(emptyItem?.title.hasPrefix("Configure:") == true)
    #expect(items.contains { $0.id == "script.\(validDef.id).run" })
  }

  @Test func commandPaletteItems_excludesScriptsWithoutSelectedWorktree() {
    let definition = ScriptDefinition(kind: .run, command: "npm run dev")
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(),
      scripts: [definition]
    )

    #expect(items.contains { $0.id == "script.\(definition.id).run" } == false)
  }

  @Test func recencyRetentionIDs_includesScriptIDs() {
    let definition = ScriptDefinition(kind: .run, command: "npm run dev")
    let ids = CommandPaletteFeature.recencyRetentionIDs(
      from: [],
      scripts: [definition]
    )

    #expect(ids.contains("script.\(definition.id).run"))
    #expect(ids.contains("script.\(definition.id).stop"))
  }

  @Test func worktreeSwitcherItems_emptyWhenNoWorktrees() {
    let items = CommandPaletteFeature.worktreeSwitcherItems(from: RepositoriesFeature.State())
    #expect(items.isEmpty)
  }

  @Test func worktreeSwitcherItems_sortsByMRUThenSidebarOrderAndMarksCurrent() {
    let wtA = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let wtB = makeWorktree(id: "/tmp/repo-b/wt", name: "wt", repoRoot: "/tmp/repo-b")
    let wtC = makeWorktree(id: "/tmp/repo-c/wt", name: "wt", repoRoot: "/tmp/repo-c")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "Alpha", worktrees: [wtA])
    let repoB = makeRepository(rootPath: "/tmp/repo-b", name: "Bravo", worktrees: [wtB])
    let repoC = makeRepository(rootPath: "/tmp/repo-c", name: "Charlie", worktrees: [wtC])
    var state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB, repoC])

    // MRU = [wtA, wtC] after select C then select A. The current worktree
    // (wtA, the MRU head) is rendered first but flagged isCurrentWorktree so
    // the overlay skips it for the default selection.
    state.setSingleWorktreeSelection(wtC.id)
    state.setSingleWorktreeSelection(wtA.id)

    let items = CommandPaletteFeature.worktreeSwitcherItems(from: state)

    // MRU head (A), then prior MRU (C), then the worktree never visited (B),
    // which trails in sidebar order.
    #expect(items.map(\.id) == [
      "worktree.\(wtA.id).select",
      "worktree.\(wtC.id).select",
      "worktree.\(wtB.id).select",
    ])
    // priorityTier mirrors visible order so an empty-query prioritizeItems()
    // pass preserves the MRU ranking even though item-level recency is empty.
    #expect(items.map(\.priorityTier) == [0, 1, 2])
    // Only the current worktree (A) carries the skip-for-default flag.
    #expect(items.map(\.isCurrentWorktree) == [true, false, false])
  }

  @Test func worktreeSwitcherItems_listsEveryWorktreeAcrossRepos() {
    // The whole point of the rework: multi-worktree repos surface every
    // worktree, not a single per-repo entry. wt1/wt2 share repoA.
    let wt1 = makeWorktree(id: "/tmp/repo-a/wt-1", name: "feature/one", repoRoot: "/tmp/repo-a")
    let wt2 = makeWorktree(id: "/tmp/repo-a/wt-2", name: "feature/two", repoRoot: "/tmp/repo-a")
    let wt3 = makeWorktree(id: "/tmp/repo-b/wt", name: "main", repoRoot: "/tmp/repo-b")
    let repoA = makeRepository(rootPath: "/tmp/repo-a", name: "Alpha", worktrees: [wt1, wt2])
    let repoB = makeRepository(rootPath: "/tmp/repo-b", name: "Bravo", worktrees: [wt3])
    let state = RepositoriesFeature.State(reconciledRepositories: [repoA, repoB])

    let items = CommandPaletteFeature.worktreeSwitcherItems(from: state)

    #expect(Set(items.map(\.id)) == [
      "worktree.\(wt1.id).select",
      "worktree.\(wt2.id).select",
      "worktree.\(wt3.id).select",
    ])
  }

  @Test func worktreeSwitcherItems_titleIsWorktreeWithRepoSubtitle() {
    let wtFeat = makeWorktree(id: "/tmp/repo/feat", name: "feature/x", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [wtFeat])
    let state = RepositoriesFeature.State(reconciledRepositories: [repo])

    let items = CommandPaletteFeature.worktreeSwitcherItems(from: state)
    // Worktree name is the prominent title; repo is the secondary subtitle so
    // the two read as a hierarchy. The fuzzy scorer matches both, so a query
    // still hits either the worktree name or the project name.
    #expect(items.first?.title == "feature/x")
    #expect(items.first?.subtitle == "Repo")
  }

  @Test func items_dispatchByMode() {
    let wtMain = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: "/tmp/repo")
    let wtOther = makeWorktree(id: "/tmp/other/wt", name: "wt", repoRoot: "/tmp/other")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [wtMain])
    let other = makeRepository(rootPath: "/tmp/other", name: "Other", worktrees: [wtOther])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo, other])
    // wtOther is current; wtMain is the previous worktree the switcher surfaces.
    state.setSingleWorktreeSelection(wtMain.id)
    state.setSingleWorktreeSelection(wtOther.id)

    let commands = CommandPaletteFeature.items(in: .commands, from: state)
    let switcher = CommandPaletteFeature.items(in: .worktreeSwitcher, from: state)

    // .commands surfaces actions only; worktree navigation moved to the switcher.
    #expect(commands.contains { $0.id.hasPrefix("global.") })
    #expect(commands.contains { $0.id == "worktree.\(wtMain.id).select" } == false)

    // .worktreeSwitcher is worktree-only, MRU-ordered. The current worktree
    // (wtOther) leads, flagged so the overlay skips it for the default
    // selection; the prior worktree (wtMain) follows.
    #expect(switcher.allSatisfy { $0.id.hasPrefix("worktree.") && $0.id.hasSuffix(".select") })
    #expect(switcher == [
      CommandPaletteItem(
        id: "worktree.\(wtOther.id).select",
        title: "wt",
        subtitle: "Other",
        kind: .worktreeSelect(wtOther.id),
        priorityTier: 0,
        isCurrentWorktree: true,
        worktreeStyle: .init(icon: .pullRequest(.branch, checkBadge: nil))
      ),
      CommandPaletteItem(
        id: "worktree.\(wtMain.id).select",
        title: "main",
        subtitle: "Repo",
        kind: .worktreeSelect(wtMain.id),
        priorityTier: 1,
        worktreeStyle: .init(icon: .pullRequest(.branch, checkBadge: nil))
      ),
    ])
  }

  @Test func commandPaletteItems_omitsWorktreeSelectRows() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
    let items = CommandPaletteFeature.commandPaletteItems(
      from: RepositoriesFeature.State(reconciledRepositories: [repo])
    )
    // The ⌘⇧P command palette lists actions only; worktree navigation is the switcher's job.
    #expect(
      items.contains {
        if case .worktreeSelect = $0.kind { return true }
        return false
      } == false
    )
  }

  @Test func directSubtitleMatchBeatsScatteredTitleWhenTitleAlsoMatches() {
    // "main" scatter-matches "mountain-*" (m-a-i-n as a subsequence). The row whose
    // repo subtitle is exactly "main" must outrank the row that only scatter-matches
    // its title: a clean repo hit beats a fuzzy worktree hit even when both titles match.
    let subtitleHit = CommandPaletteItem(
      id: "worktree.x.select", title: "mountain-xyz", subtitle: "main", kind: .worktreeSelect("x")
    )
    let titleScatterOnly = CommandPaletteItem(
      id: "worktree.y.select", title: "mountain-abc", subtitle: "other", kind: .worktreeSelect("y")
    )
    let result = CommandPaletteFeature.filterItems(items: [titleScatterOnly, subtitleHit], query: "main")
    #expect(result.map(\.id) == ["worktree.x.select", "worktree.y.select"])
  }

  @Test func directSubstringBeatsScatteredMatchOnLongTarget() {
    // A direct substring hit outranks a scattered subsequence hit even when the
    // scattered hit is on a very long title, whose in-tier score is clamped so it
    // cannot bleed past the higher direct tier.
    let longScatter = CommandPaletteItem(
      id: "worktree.long.select",
      title: "abazzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzc",
      subtitle: nil,
      kind: .worktreeSelect("long")
    )
    let directShort = CommandPaletteItem(
      id: "worktree.short.select", title: "xabc", subtitle: nil, kind: .worktreeSelect("short")
    )
    let result = CommandPaletteFeature.filterItems(items: [longScatter, directShort], query: "abc")
    #expect(result.first?.id == "worktree.short.select")
  }

  @Test func filterItems_worktreeSwitcherEmptyQueryListsAllWorktrees() {
    let current = CommandPaletteItem(
      id: "worktree.a.select", title: "a", subtitle: "R", kind: .worktreeSelect("a"),
      priorityTier: 0, isCurrentWorktree: true
    )
    let prev = CommandPaletteItem(
      id: "worktree.b.select", title: "b", subtitle: "R", kind: .worktreeSelect("b"), priorityTier: 1
    )
    // The switcher lists every worktree (including the current one) with an empty
    // query, in priorityTier (MRU) order, unlike the commands palette which hides them.
    let result = CommandPaletteFeature.filterItems(items: [current, prev], query: "", mode: .worktreeSwitcher)
    #expect(result.map(\.id) == ["worktree.a.select", "worktree.b.select"])
  }

  @Test func defaultSelectionIndex_skipsCurrentWorktreeOnEmptyQuery() {
    let current = CommandPaletteItem(
      id: "worktree.a.select", title: "a", subtitle: "R", kind: .worktreeSelect("a"),
      priorityTier: 0, isCurrentWorktree: true
    )
    let prev = CommandPaletteItem(
      id: "worktree.b.select", title: "b", subtitle: "R", kind: .worktreeSelect("b"), priorityTier: 1
    )
    // Empty query + current worktree at index 0 lands on the previous worktree (1).
    #expect(CommandPaletteFeature.defaultSelectionIndex(rows: [current, prev], query: "") == 1)
  }

  @Test func defaultSelectionIndex_topRowWhenQueryNonEmptyOrHeadNotCurrent() {
    let current = CommandPaletteItem(
      id: "worktree.a.select", title: "a", subtitle: "R", kind: .worktreeSelect("a"),
      priorityTier: 0, isCurrentWorktree: true
    )
    let prev = CommandPaletteItem(
      id: "worktree.b.select", title: "b", subtitle: "R", kind: .worktreeSelect("b"), priorityTier: 1
    )
    // Once the user types, the top fuzzy match wins even if it is the current worktree.
    #expect(CommandPaletteFeature.defaultSelectionIndex(rows: [current, prev], query: "a") == 0)
    // A lone current row still selects index 0 (nothing else to jump to).
    #expect(CommandPaletteFeature.defaultSelectionIndex(rows: [current], query: "") == 0)
    // When the head isn't the current worktree, don't skip it.
    #expect(CommandPaletteFeature.defaultSelectionIndex(rows: [prev, current], query: "") == 0)
  }

  @Test func presentInMode_sameModeWhilePresentedPreservesQuery() async {
    let store = TestStore(
      initialState: CommandPaletteFeature.State(
        isPresented: true, mode: .worktreeSwitcher, query: "feat", selectedIndex: 2
      )
    ) {
      CommandPaletteFeature()
    }
    // Re-pressing the same mode while open is a no-op: the in-flight query and selection survive.
    await store.send(.presentInMode(.worktreeSwitcher))
  }

  @Test func presentInMode_switchingModeWhilePresentedResets() async {
    let store = TestStore(
      initialState: CommandPaletteFeature.State(
        isPresented: true, mode: .commands, query: "x", selectedIndex: 3
      )
    ) {
      CommandPaletteFeature()
    }
    // Switching mode while open clears the query and selection and swaps the surface.
    await store.send(.presentInMode(.worktreeSwitcher)) {
      $0.mode = .worktreeSwitcher
      $0.query = ""
      $0.selectedIndex = nil
    }
  }

  @Test func worktreeSwitcherItems_appliesRepoColorWorktreeTintAndHost() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    // Repo color lives on the sidebar section; the per-worktree tint and host on the row.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repo.id] ?? .init()
      section.color = .blue
      sidebar.sections[repo.id] = section
    }
    state.sidebarItems[id: worktree.id]?.customTint = .red
    let host = RemoteHost(alias: "beacon")
    state.sidebarItems[id: worktree.id]?.host = host

    let item = CommandPaletteFeature.worktreeSwitcherItems(from: state).first
    #expect(item?.title == "feature")
    #expect(item?.subtitle == "Repo")
    // Worktree name takes its own tint; the repo subtitle takes the repo color.
    #expect(item?.worktreeStyle?.titleTint == .red)
    #expect(item?.worktreeStyle?.repoTint == .blue)
    #expect(item?.worktreeStyle?.hostInfo == host.displayAuthority)
    // A git worktree with no linked pull request shows the branch glyph, no badge.
    #expect(item?.worktreeStyle?.icon == .pullRequest(.branch, checkBadge: nil))
  }

  @Test func worktreeSwitcherItems_folderUsesCustomNameAndColorNoSubtitle() {
    let folderURL = URL(fileURLWithPath: "/tmp/my-folder")
    let folderID = Repository.folderWorktreeID(for: folderURL)
    let folderRepo = Repository(
      id: RepositoryID(folderURL.path(percentEncoded: false)),
      rootURL: folderURL,
      name: "my-folder",
      worktrees: IdentifiedArray(uniqueElements: [
        Worktree(id: folderID, name: "my-folder", detail: "", workingDirectory: folderURL, repositoryRootURL: folderURL)
      ]),
      isGitRepository: false
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [folderRepo])
    // A folder's custom name / color live on the sidebar section.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[folderRepo.id] ?? .init()
      section.title = "Design Docs"
      section.color = .teal
      sidebar.sections[folderRepo.id] = section
    }

    let item = CommandPaletteFeature.worktreeSwitcherItems(from: state).first
    // A folder shows its custom name as the title (tinted with the folder color) and
    // carries no repo subtitle, so the name never doubles up.
    #expect(item?.title == "Design Docs")
    #expect(item?.subtitle == nil)
    #expect(item?.worktreeStyle?.titleTint == .teal)
    #expect(item?.worktreeStyle?.repoTint == nil)
    #expect(item?.worktreeStyle?.icon == .folder)
  }

  @Test func worktreeSwitcherItems_iconMissingWinsOverPullRequest() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.sidebarItems[id: worktree.id]?.isMissing = true
    state.sidebarItems[id: worktree.id]?.pullRequest = makePullRequest(state: "OPEN")

    let item = CommandPaletteFeature.worktreeSwitcherItems(from: state).first
    // A missing working directory wins over the pull-request glyph.
    #expect(item?.worktreeStyle?.icon == .missing)
  }

  @Test func worktreeSwitcherItems_iconIgnoresStalePullRequestOffBranch() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    // The row moved to a branch that no longer matches the PR head ("feature").
    state.sidebarItems[id: worktree.id]?.branchName = "moved-off"
    let failingCheck = GithubPullRequestStatusCheck(
      detailsUrl: "https://example.com/check/1",
      status: "COMPLETED",
      conclusion: "FAILURE",
      state: nil
    )
    state.sidebarItems[id: worktree.id]?.pullRequest = makePullRequest(state: "OPEN", checks: [failingCheck])

    let item = CommandPaletteFeature.worktreeSwitcherItems(from: state).first
    // A stale PR (head branch != row branch) collapses to the branch glyph and drops the badge.
    #expect(item?.worktreeStyle?.icon == .pullRequest(.branch, checkBadge: nil))
  }

  @Test func worktreeSwitcherItems_iconBadgesPassingAndInProgressChecks() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])

    var passingState = RepositoriesFeature.State(reconciledRepositories: [repo])
    passingState.sidebarItems[id: worktree.id]?.pullRequest = makePullRequest(
      state: "OPEN",
      checks: [GithubPullRequestStatusCheck(status: "COMPLETED", conclusion: "SUCCESS", state: nil)]
    )
    #expect(
      CommandPaletteFeature.worktreeSwitcherItems(from: passingState).first?.worktreeStyle?.icon
        == .pullRequest(.open, checkBadge: .passing))

    var inProgressState = RepositoriesFeature.State(reconciledRepositories: [repo])
    inProgressState.sidebarItems[id: worktree.id]?.pullRequest = makePullRequest(
      state: "OPEN",
      checks: [GithubPullRequestStatusCheck(status: "IN_PROGRESS", conclusion: nil, state: nil)]
    )
    #expect(
      CommandPaletteFeature.worktreeSwitcherItems(from: inProgressState).first?.worktreeStyle?.icon
        == .pullRequest(.open, checkBadge: .inProgress))
  }

  @Test func worktreeSwitcherItems_iconReflectsPullRequestState() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    state.sidebarItems[id: worktree.id]?.pullRequest = makePullRequest(state: "OPEN")

    let item = CommandPaletteFeature.worktreeSwitcherItems(from: state).first
    // An open pull request with no checks lifts the branch glyph to the open-PR
    // variant and carries no check badge.
    #expect(item?.worktreeStyle?.icon == .pullRequest(.open, checkBadge: nil))
  }

  @Test func worktreeSwitcherItems_iconBadgesFailingChecks() {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "feature", repoRoot: "/tmp/repo")
    let repo = makeRepository(rootPath: "/tmp/repo", name: "Repo", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repo])
    let failingCheck = GithubPullRequestStatusCheck(
      detailsUrl: "https://example.com/check/1",
      status: "COMPLETED",
      conclusion: "FAILURE",
      state: nil
    )
    state.sidebarItems[id: worktree.id]?.pullRequest = makePullRequest(
      state: "OPEN",
      checks: [failingCheck]
    )

    let item = CommandPaletteFeature.worktreeSwitcherItems(from: state).first
    // A failing check surfaces the red check badge over the open-PR glyph.
    #expect(item?.worktreeStyle?.icon == .pullRequest(.open, checkBadge: .failing))
  }

  @Test func presentInMode_setsModeAndPresentsTheView() async {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }

    await store.send(.presentInMode(.worktreeSwitcher)) {
      $0.isPresented = true
      $0.mode = .worktreeSwitcher
    }
  }

  @Test func setPresented_falseFromPresentedEmitsDismissedDelegate() async {
    let store = TestStore(
      initialState: CommandPaletteFeature.State(isPresented: true, mode: .worktreeSwitcher)
    ) {
      CommandPaletteFeature()
    }

    await store.send(.setPresented(false)) {
      $0.isPresented = false
      $0.mode = .commands
    }
    await store.receive(\.delegate.dismissedWithoutSelection)
  }

  @Test func setPresented_falseFromNotPresentedDoesNotEmitDelegate() async {
    let store = TestStore(initialState: CommandPaletteFeature.State()) {
      CommandPaletteFeature()
    }
    await store.send(.setPresented(false))
  }

  @Test func togglePresented_dismissEmitsDelegate() async {
    let store = TestStore(initialState: CommandPaletteFeature.State(isPresented: true)) {
      CommandPaletteFeature()
    }

    await store.send(.togglePresented) {
      $0.isPresented = false
    }
    await store.receive(\.delegate.dismissedWithoutSelection)
  }

  @Test func activateItem_doesNotEmitDismissedDelegate() async {
    let store = TestStore(initialState: CommandPaletteFeature.State(isPresented: true)) {
      CommandPaletteFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 0)
    }

    let item = CommandPaletteItem(
      id: "global.open-settings",
      title: "Open Settings",
      subtitle: nil,
      kind: .openSettings
    )
    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.recencyByItemID[item.id] = 0
    }
    // The activation delegate carries the focus — no dismissal echo.
    await store.receive(\.delegate.openSettings)
  }
}

private func makeWorktree(
  id: String,
  name: String,
  detail: String = "detail",
  repoRoot: String,
  workingDirectory: String? = nil
) -> Worktree {
  Worktree(
    id: WorktreeID(id),
    name: name,
    detail: detail,
    workingDirectory: URL(fileURLWithPath: workingDirectory ?? id),
    repositoryRootURL: URL(fileURLWithPath: repoRoot)
  )
}

private func makeRepository(
  rootPath: String,
  name: String,
  worktrees: [Worktree]
) -> Repository {
  let rootURL = URL(fileURLWithPath: rootPath)
  return Repository(
    id: RepositoryID(rootURL.path(percentEncoded: false)),
    rootURL: rootURL,
    name: name,
    worktrees: IdentifiedArray(uniqueElements: worktrees)
  )
}

private func makePullRequest(
  state: String = "OPEN",
  isDraft: Bool = false,
  reviewDecision: String? = nil,
  mergeable: String? = nil,
  mergeStateStatus: String? = nil,
  checks: [GithubPullRequestStatusCheck] = []
) -> GithubPullRequest {
  GithubPullRequest(
    number: 1,
    title: "PR",
    state: state,
    additions: 0,
    deletions: 0,
    isDraft: isDraft,
    reviewDecision: reviewDecision,
    mergeable: mergeable,
    mergeStateStatus: mergeStateStatus,
    updatedAt: nil,
    url: "https://example.com/pull/1",
    headRefName: "feature",
    baseRefName: "main",
    commitsCount: 1,
    authorLogin: "khoi",
    statusCheckRollup: checks.isEmpty ? nil : GithubPullRequestStatusCheckRollup(checks: checks),
    mergeQueueEntry: nil
  )
}
