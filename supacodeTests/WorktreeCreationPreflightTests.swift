import Foundation
import Testing

@testable import supacode

struct WorktreeCreationPreflightTests {
  private let repositoryRootURL = URL(fileURLWithPath: "/tmp/preflight-repo")

  private func makeWorktree(path: String, name: String) -> Worktree {
    Worktree(
      location: .local(workingDirectory: URL(fileURLWithPath: path), repositoryRoot: repositoryRootURL),
      kind: .git,
      name: name,
      detail: "",
      createdAt: nil
    )
  }

  @Test func conflictingBranchFlagsBothNamespaceDirections() {
    let branches: Set<String> = ["main", "experiments/a", "release"]
    #expect(WorktreeCreationPreflight.conflictingBranch(for: "experiments", among: branches) == "experiments/a")
    #expect(WorktreeCreationPreflight.conflictingBranch(for: "release/1.0", among: branches) == "release")
    #expect(WorktreeCreationPreflight.conflictingBranch(for: "Experiments", among: branches) == "experiments/a")
  }

  @Test func conflictingBranchIgnoresPlainPrefixes() {
    let branches: Set<String> = ["experiments-old", "exp/a"]
    #expect(WorktreeCreationPreflight.conflictingBranch(for: "experiments", among: branches) == nil)
    #expect(WorktreeCreationPreflight.conflictingBranch(for: "exp-b", among: branches) == nil)
  }

  @Test func namespacesListEveryParentLevel() {
    let namespaces = WorktreeCreationPreflight.namespaces(of: ["a/b/c", "Feature/x", "main"])
    #expect(namespaces == ["a", "a/b", "feature"])
  }

  @Test func claimOrdersExactNamespaceFolderThenNesting() {
    let target = URL(fileURLWithPath: "/tmp/preflight-base/experiments")
    func claim(
      names: Set<String> = [],
      state: WorktreeTargetState = .absent,
      worktrees: [Worktree] = []
    ) -> Result<WorktreeCreationCleanupTarget, WorktreeCreationPreflight.Rejection> {
      WorktreeCreationPreflight.claim(
        branchName: "experiments",
        targetDirectory: target,
        targetState: state,
        takenNames: WorktreeCreationPreflight.TakenNames(branches: names),
        worktrees: worktrees
      )
    }
    let expectedTarget = WorktreeCreationCleanupTarget(
      branchName: "experiments", directory: target, directoryPreexisted: false)
    #expect(claim() == .success(expectedTarget))
    #expect(claim(names: ["Experiments"]) == .failure(.nameTaken))
    #expect(
      claim(names: ["Experiments/A"], state: .occupied) == .failure(.namespaceConflict(branch: "Experiments/A")))
    #expect(claim(state: .occupied) == .failure(.folderOccupied(target)))
    let enclosing = makeWorktree(path: "/tmp/preflight-base", name: "other")
    #expect(
      claim(state: .occupied, worktrees: [enclosing]) == .failure(.folderOccupied(target)))
    #expect(claim(worktrees: [enclosing]) == .failure(.insideWorktree(target, worktreeName: "other")))
  }

  @Test func detachedWorktreeNameBlocksOnlyItsExactName() {
    // A detached worktree's name is its folder leaf, not a ref, so it reserves no namespace.
    let target = URL(fileURLWithPath: "/tmp/preflight-base/review/fix-x")
    let names = WorktreeCreationPreflight.TakenNames(branches: ["main"], worktrees: ["review"])
    func claim(_ branch: String) -> Result<WorktreeCreationCleanupTarget, WorktreeCreationPreflight.Rejection> {
      WorktreeCreationPreflight.claim(
        branchName: branch, targetDirectory: target, targetState: .absent, takenNames: names, worktrees: [])
    }
    #expect(
      claim("review/fix-x")
        == .success(
          WorktreeCreationCleanupTarget(branchName: "review/fix-x", directory: target, directoryPreexisted: false)))
    #expect(claim("Review") == .failure(.nameTaken))
  }

  @Test func claimMarksPreexistingEmptyFolder() {
    let target = URL(fileURLWithPath: "/tmp/preflight-base/experiments")
    let result = WorktreeCreationPreflight.claim(
      branchName: "experiments",
      targetDirectory: target,
      targetState: .emptyDirectory,
      takenNames: WorktreeCreationPreflight.TakenNames(branches: []),
      worktrees: []
    )
    #expect(
      result
        == .success(
          WorktreeCreationCleanupTarget(branchName: "experiments", directory: target, directoryPreexisted: true)))
  }

  @Test func worktreeAddAnnouncementMatchesOnlyThisNewBranch() {
    let target = WorktreeCreationCleanupTarget(
      branchName: "feature", directory: URL(fileURLWithPath: "/tmp/x"), directoryPreexisted: false)
    #expect(target.isWorktreeAddAnnouncement("Preparing worktree (new branch 'feature')\n"))
    #expect(!target.isWorktreeAddAnnouncement("Preparing worktree (checking out 'feature')"))
    #expect(!target.isWorktreeAddAnnouncement("Preparing worktree (new branch 'feature/x')"))
  }

  @Test func worktreeAddAnnouncementMatchesTheReusedBranchCheckout() {
    let target = WorktreeCreationCleanupTarget(
      branchName: "feature", directory: URL(fileURLWithPath: "/tmp/x"), directoryPreexisted: false,
      reusesBranch: true)
    #expect(target.isWorktreeAddAnnouncement("Preparing worktree (checking out 'feature')\n"))
    #expect(!target.isWorktreeAddAnnouncement("Preparing worktree (new branch 'feature')"))
  }

  @Test func reuseClaimsAnUnusedBranchOnly() {
    let target = URL(fileURLWithPath: "/tmp/preflight-base/feature")
    func claim(
      _ existingBranch: GitBranchAvailability,
      names: WorktreeCreationPreflight.TakenNames = .init(branches: ["feature", "main"]),
      state: WorktreeTargetState = .absent
    ) -> Result<WorktreeCreationCleanupTarget, WorktreeCreationPreflight.Rejection> {
      WorktreeCreationPreflight.claim(
        branchName: "feature", targetDirectory: target, targetState: state, takenNames: names, worktrees: [],
        existingBranch: existingBranch)
    }
    #expect(claim(.absent) == .failure(.nameTaken))
    #expect(
      claim(.reusable)
        == .success(
          WorktreeCreationCleanupTarget(
            branchName: "feature", directory: target, directoryPreexisted: false, reusesBranch: true)))
    #expect(claim(.checkedOut("/tmp/wt/feature")) == .failure(.branchCheckedOut(worktreePath: "/tmp/wt/feature")))
    // A reuse still yields to an in-flight creation of the name and to the folder checks.
    #expect(claim(.reusable, names: .init(branches: ["feature"], inFlight: ["feature"])) == .failure(.nameTaken))
    #expect(claim(.reusable, state: .occupied) == .failure(.folderOccupied(target)))
  }

  @Test func enclosingWorktreeMatchesCaseInsensitively() {
    let feature = makeWorktree(path: "/tmp/preflight-base/feature", name: "feature")
    let target = URL(fileURLWithPath: "/tmp/preflight-base/Feature/nested")
    #expect(WorktreeCreationPreflight.enclosingWorktree(of: target, in: [feature])?.name == "feature")
  }

  @Test func enclosingWorktreeSkipsMainWorktree() {
    let main = makeWorktree(path: repositoryRootURL.path(percentEncoded: false), name: "main")
    let target = repositoryRootURL.appending(path: ".worktrees/feature")
    #expect(
      WorktreeCreationPreflight.enclosingWorktree(
        of: target, in: [main]) == nil)
  }

  @Test func enclosingWorktreeIgnoresSiblingsAndChildren() {
    let sibling = makeWorktree(path: "/tmp/preflight-base/experiments-old", name: "experiments-old")
    let child = makeWorktree(path: "/tmp/preflight-base/experiments/a", name: "experiments/a")
    let target = URL(fileURLWithPath: "/tmp/preflight-base/experiments")
    #expect(
      WorktreeCreationPreflight.enclosingWorktree(
        of: target, in: [sibling, child]) == nil)
  }

  @Test func isSameDirectoryResolvesSymlinkedAncestors() throws {
    let fileManager = FileManager.default
    let real = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    let link = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: real)
    defer {
      try? fileManager.removeItem(at: link)
      try? fileManager.removeItem(at: real)
    }
    #expect(
      WorktreeCreationPreflight.isSameDirectory(
        link.appending(path: "not-yet-created"), real.appending(path: "not-yet-created")))
    #expect(
      !WorktreeCreationPreflight.isSameDirectory(
        link.appending(path: "a"), real.appending(path: "b")))
  }
}
