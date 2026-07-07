import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeAppearanceQueryResponseTests {
  @Test func unsetCustomizationReportsStoredFieldsSeparatelyFromDisplayTitle() {
    let (repository, worktree) = makeGitWorktree(name: "feature/review")

    let fields = WorktreeAppearanceQueryResponse.fields(
      repository: repository, worktree: worktree, item: nil)

    #expect(fields["title"] == "")
    #expect(fields["color"] == "none")
    #expect(fields["displayTitle"] == "feature/review")
  }

  @Test func storedCustomizationReportsRawOverridesAndTrimmedDisplayTitle() {
    let (repository, worktree) = makeGitWorktree(name: "feature/review")
    let item = SidebarState.Item(title: "  Review UI  ", color: .purple)

    let fields = WorktreeAppearanceQueryResponse.fields(
      repository: repository, worktree: worktree, item: item)

    #expect(fields["title"] == "  Review UI  ")
    #expect(fields["color"] == "purple")
    #expect(fields["displayTitle"] == "Review UI")
  }

  @Test func displayTitleReflectsBranchNameNotFolderBasename() {
    // Folder basename ("review") differs from the branch name; the sidebar row
    // titles with the branch, so `displayTitle` must too.
    let (repository, worktree) = makeGitWorktree(name: "feature/review")

    let fields = WorktreeAppearanceQueryResponse.fields(
      repository: repository, worktree: worktree, item: nil)

    #expect(fields["displayTitle"] == "feature/review")
  }

  @Test func folderDisplayTitleFallsBackToRepositoryName() {
    let (repository, worktree) = makeFolderWorktree(repositoryName: "Documents", worktreeName: "Synthetic Row")

    let fields = WorktreeAppearanceQueryResponse.fields(
      repository: repository, worktree: worktree, item: nil)

    #expect(fields["title"] == "")
    #expect(fields["color"] == "none")
    #expect(fields["displayTitle"] == "Documents")
  }

  private func makeGitWorktree(name: String) -> (Repository, Worktree) {
    let rootURL = URL(fileURLWithPath: "/tmp/supacode")
    let worktreeURL = rootURL.appendingPathComponent(name)
    let worktree = Worktree(
      id: WorktreeID(worktreeURL.path(percentEncoded: false)),
      kind: .git,
      name: name,
      detail: "",
      workingDirectory: worktreeURL,
      repositoryRootURL: rootURL
    )
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: "supacode",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    return (repository, worktree)
  }

  private func makeFolderWorktree(repositoryName: String, worktreeName: String) -> (Repository, Worktree) {
    let rootURL = URL(fileURLWithPath: "/tmp/\(repositoryName)")
    let worktree = Worktree(
      id: Repository.folderWorktreeID(for: rootURL),
      kind: .folder,
      name: worktreeName,
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL,
      isAttached: false
    )
    let repository = Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: repositoryName,
      worktrees: IdentifiedArray(uniqueElements: [worktree]),
      isGitRepository: false
    )
    return (repository, worktree)
  }
}
