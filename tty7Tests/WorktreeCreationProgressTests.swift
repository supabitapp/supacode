import Testing

@testable import tty7

struct WorktreeCreationProgressTests {
  @Test func fetchingOriginShowsDetailTextWithRemoteName() {
    let progress = WorktreeCreationProgress(
      stage: .fetchingOrigin,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      fetchRemoteName: "origin",
    )

    #expect(progress.titleText == "Creating swift-otter")
    #expect(progress.detailText == "Fetching latest from origin")
  }

  @Test func fetchingOriginShowsGenericTextWhenRemoteNameMissing() {
    let progress = WorktreeCreationProgress(
      stage: .fetchingOrigin,
      worktreeName: "swift-otter",
    )

    #expect(progress.detailText == "Fetching latest from remote")
  }

  @Test func fetchingOriginShowsCustomRemoteName() {
    let progress = WorktreeCreationProgress(
      stage: .fetchingOrigin,
      worktreeName: "swift-otter",
      fetchRemoteName: "upstream",
    )

    #expect(progress.detailText == "Fetching latest from upstream")
  }

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
        == "Creating from main branch. Copying 12 ignored files"
    )
  }

  @Test func creatingWorktreePrefersLatestOutputLineWhenAvailable() {
    let progress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: true,
      copyUntracked: true,
      ignoredFilesToCopyCount: 12,
      untrackedFilesToCopyCount: 5,
      latestOutputLine: "[23/100] copy dist/bundle.js"
    )

    #expect(progress.detailText == "[23/100] copy dist/bundle.js")
  }

  @Test func creatingWorktreePrefersLatestBufferedOutputLineWhenAvailable() {
    let progress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: true,
      copyUntracked: true,
      ignoredFilesToCopyCount: 12,
      untrackedFilesToCopyCount: 5,
      latestOutputLine: "[23/100] copy dist/bundle.js",
      outputLines: [
        "[22/100] copy src/app.js",
        "[23/100] copy dist/bundle.js",
      ]
    )

    #expect(progress.detailText == "[23/100] copy dist/bundle.js")
    #expect(progress.liveOutputLines == ["[22/100] copy src/app.js", "[23/100] copy dist/bundle.js"])
  }

  @Test func appendOutputLineKeepsLatestAndLimitsBuffer() {
    var progress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter"
    )

    progress.appendOutputLine("[1/5] copy .env", maxLines: 3)
    progress.appendOutputLine("[2/5] copy .cache", maxLines: 3)
    progress.appendOutputLine("[3/5] copy README.md", maxLines: 3)
    progress.appendOutputLine("[4/5] copy build.log", maxLines: 3)
    progress.appendOutputLine("[5/5] copy output.bin", maxLines: 3)

    #expect(progress.latestOutputLine == "[5/5] copy output.bin")
    #expect(progress.outputLines == ["[3/5] copy README.md", "[4/5] copy build.log", "[5/5] copy output.bin"])
    #expect(progress.liveOutputLines == ["[3/5] copy README.md", "[4/5] copy build.log", "[5/5] copy output.bin"])
    #expect(progress.detailText == "[5/5] copy output.bin")
  }
}
