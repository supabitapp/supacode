import Testing

@testable import supacode

struct WorktreeCreationProgressTests {
  @Test func resolvingBaseReferenceUsesHeadFallback() {
    let progress = WorktreeCreationProgress(
      stage: .resolvingBaseReference,
      worktreeName: "swift-otter"
    )

    #expect(progress.titleText == "Creating swift-otter")
    #expect(progress.detailText == "Resolving base reference (HEAD)")
  }

  @Test func creatingWorktreeIncludesBaseRefAndCopyFlags() {
    let progress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: true,
      copyUntracked: false,
      ignoredFilesToCopyCount: 12,
      untrackedFilesToCopyCount: 5
    )

    #expect(progress.titleText == "Creating swift-otter")
    #expect(
      progress.detailText
        == "Creating from main branch. Copying 12 ignored files and copying 0 untracked files"
    )
  }

  @Test func creatingWorktreeIncludesLatestCopyProgressReport() {
    let progress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: true,
      copyUntracked: false,
      copyProgressReport: "2/12 README.md",
      ignoredFilesToCopyCount: 12
    )

    #expect(
      progress.detailText == "Creating from main branch. Copying 12 ignored files. Latest copy: 2/12 README.md"
    )
  }
}
