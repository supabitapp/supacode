import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct ResolvedRowDisplayTests {
  // MARK: - Folder rows.

  @Test func folderKindRendersBranchAsTitleAndDropsSubtitle() {
    let resolved = ResolvedRowDisplay(
      kind: .folder,
      branchName: "Documents",
      worktreeName: "Documents",
      isMainWorktree: true,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    #expect(resolved.name == "Documents")
    #expect(resolved.subtitle == .none)
  }

  @Test func folderKindIgnoresHighlightTagSinceFolderIsTheRepo() {
    let resolved = ResolvedRowDisplay(
      kind: .folder,
      branchName: "Notes",
      worktreeName: nil,
      isMainWorktree: true,
      isPinned: true,
      hideSubtitle: false,
      hideSubtitleOnMatch: false,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "Notes", repoColor: nil, hostInfo: nil)
    )
    #expect(resolved.subtitle == .none)
  }

  // MARK: - Per-repo subtitle path (no highlight tag).

  @Test func plainSubtitleShowsWorktreeNameWhenNoMatch() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "scratch",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    #expect(resolved.subtitle == .plain("scratch"))
  }

  @Test func plainSubtitleHidesWhenWorktreeMatchesBranchLastComponentAndFlagOn() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "foo",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    #expect(resolved.subtitle == .none)
  }

  @Test func plainSubtitleKeepsMatchingWorktreeNameWhenFlagOff() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "foo",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: false
    )
    #expect(resolved.subtitle == .plain("foo"))
  }

  @Test func plainSubtitleSuppressedUnconditionallyByHideSubtitle() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "scratch",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: true,
      hideSubtitleOnMatch: false
    )
    #expect(resolved.subtitle == .none)
  }

  // MARK: - Highlight trail resolution (the four branches).

  @Test func highlightTrailIsDefaultForMainWorktree() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "main",
      worktreeName: nil,
      isMainWorktree: true,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "supacode", repoColor: .blue, hostInfo: nil)
    )
    guard case .highlight(let repo, let color, let trail, _) = resolved.subtitle else {
      Issue.record("Expected .highlight subtitle for main worktree")
      return
    }
    #expect(repo == "supacode")
    #expect(color == .blue)
    #expect(trail == "Default")
  }

  @Test func highlightTrailHidesOnMatchWhenFlagOn() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "foo",
      isMainWorktree: false,
      isPinned: true,
      hideSubtitle: false,
      hideSubtitleOnMatch: true,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "supacode", repoColor: nil, hostInfo: nil)
    )
    guard case .highlight(_, _, let trail, _) = resolved.subtitle else {
      Issue.record("Expected .highlight subtitle")
      return
    }
    #expect(trail == nil)
  }

  @Test func highlightTrailKeepsMatchingWorktreeNameWhenFlagOff() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "foo",
      isMainWorktree: false,
      isPinned: true,
      hideSubtitle: false,
      hideSubtitleOnMatch: false,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "supacode", repoColor: nil, hostInfo: nil)
    )
    guard case .highlight(_, _, let trail, _) = resolved.subtitle else {
      Issue.record("Expected .highlight subtitle")
      return
    }
    #expect(trail == "foo")
  }

  @Test func highlightTrailUsesWorktreeNameWhenPresent() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "scratch",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "supacode", repoColor: nil, hostInfo: nil)
    )
    guard case .highlight(_, _, let trail, _) = resolved.subtitle else {
      Issue.record("Expected .highlight subtitle")
      return
    }
    #expect(trail == "scratch")
  }

  @Test func highlightTrailCollapsesToRepoWhenWorktreeNameMissing() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: nil,
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "supacode", repoColor: nil, hostInfo: nil)
    )
    guard case .highlight(_, _, let trail, _) = resolved.subtitle else {
      Issue.record("Expected .highlight subtitle")
      return
    }
    #expect(trail == nil)
  }

  // MARK: - Hide-on-match parity across the two render paths.

  @Test func hideOnMatchParityBetweenHighlightAndPlainPaths() {
    let plain = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "foo",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    let highlight = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature/foo",
      worktreeName: "foo",
      isMainWorktree: false,
      isPinned: true,
      hideSubtitle: false,
      hideSubtitleOnMatch: true,
      highlightSubtitle: SidebarHighlightRepoTag(repoName: "supacode", repoColor: nil, hostInfo: nil)
    )
    #expect(plain.subtitle == .none)
    if case .highlight(_, _, let trail, _) = highlight.subtitle {
      #expect(trail == nil)
    } else {
      Issue.record("Expected .highlight subtitle for the hoisted path")
    }
  }

  // MARK: - Accent resolution.

  @Test func accentIsMainForMainWorktreeRegardlessOfPin() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "main",
      worktreeName: nil,
      isMainWorktree: true,
      isPinned: true,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    #expect(resolved.accent == .main)
  }

  @Test func accentIsPinnedWhenPinnedAndNotMain() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature",
      worktreeName: "scratch",
      isMainWorktree: false,
      isPinned: true,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    #expect(resolved.accent == .pinned)
  }

  @Test func accentIsDefaultWhenNeitherMainNorPinned() {
    let resolved = ResolvedRowDisplay(
      kind: .gitWorktree,
      branchName: "feature",
      worktreeName: "scratch",
      isMainWorktree: false,
      isPinned: false,
      hideSubtitle: false,
      hideSubtitleOnMatch: true
    )
    #expect(resolved.accent == .default)
  }
}
