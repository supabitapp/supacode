import Foundation
import Testing

@testable import Tty7SettingsShared
@testable import tty7

struct RepositoryNameTests {
  @Test func usesParentDirectoryNameForBareRepositoryRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")

    #expect(Repository.name(for: root) == "repo-alpha")
  }

  @Test func preservesNormalRepositoryName() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")

    #expect(Repository.name(for: root) == "repo-alpha")
  }
}

struct Tty7PathsTests {
  @Test func repositoryDirectoryUsesRepoNameForNormalRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = Tty7Paths.repositoryDirectory(for: root)

    #expect(directory.lastPathComponent == "repo-alpha")
  }

  @Test func repositoryDirectoryUsesSanitizedPathForBareRoots() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let directory = Tty7Paths.repositoryDirectory(for: root)

    #expect(directory.lastPathComponent == "tmp_work_repo-alpha_.bare")
  }

  @Test func repositoryDirectoryDoesNotCollideForDifferentBareRoots() {
    let firstRoot = URL(fileURLWithPath: "/tmp/work/repo-alpha/.bare")
    let secondRoot = URL(fileURLWithPath: "/tmp/work/repo-beta/.bare")

    let firstDirectory = Tty7Paths.repositoryDirectory(for: firstRoot)
    let secondDirectory = Tty7Paths.repositoryDirectory(for: secondRoot)

    #expect(firstDirectory != secondDirectory)
  }

  @Test func worktreeBaseDirectoryDefaultsToLegacyRepositoryDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = Tty7Paths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )

    #expect(directory == Tty7Paths.repositoryDirectory(for: root))
  }

  @Test func worktreeBaseDirectoryUsesGlobalParentDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = Tty7Paths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: nil
    )
    let expectedDirectory = URL(filePath: "/tmp/worktrees/repo-alpha", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(directory == expectedDirectory)
  }

  @Test func worktreeBaseDirectoryRepositoryOverrideTakesPrecedence() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let directory = Tty7Paths.worktreeBaseDirectory(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: "/tmp/repo-alpha-worktrees"
    )
    let expectedDirectory = URL(filePath: "/tmp/repo-alpha-worktrees", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(directory == expectedDirectory)
  }

  @Test func normalizedWorktreeBaseDirectoryPathExpandsNamedTildePaths() {
    let username = NSUserName()
    let input = "~\(username)/worktrees"
    let normalizedPath = Tty7Paths.normalizedWorktreeBaseDirectoryPath(input)
    let expectedPath = URL(
      filePath: NSString(string: input).expandingTildeInPath,
      directoryHint: .isDirectory
    )
    .standardizedFileURL
    .path(percentEncoded: false)

    #expect(normalizedPath == expectedPath)
  }

  @Test func exampleWorktreePathUsesResolvedBaseDirectory() {
    let root = URL(fileURLWithPath: "/tmp/work/repo-alpha")
    let path = Tty7Paths.exampleWorktreePath(
      for: root,
      globalDefaultPath: "/tmp/worktrees",
      repositoryOverridePath: nil
    )
    let expectedPath = URL(filePath: "/tmp/worktrees/repo-alpha/swift-otter", directoryHint: .isDirectory)
      .standardizedFileURL
      .path(percentEncoded: false)

    #expect(path == expectedPath)
  }

  @Test func resolvedWorktreeDirectoryReturnsNilWhenNoOverrides() {
    let resolved = Tty7Paths.resolvedWorktreeDirectory(
      defaultBaseDirectory: URL(filePath: "/tmp/base", directoryHint: .isDirectory),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      nameOverride: "  ",
      pathOverride: nil,
      branchName: "feature/foo"
    )

    #expect(resolved == nil)
  }

  @Test func resolvedWorktreeDirectoryUsesNameOverrideUnderDefaultBase() {
    let resolved = Tty7Paths.resolvedWorktreeDirectory(
      defaultBaseDirectory: URL(filePath: "/tmp/base", directoryHint: .isDirectory),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      nameOverride: "feature_foo",
      pathOverride: nil,
      branchName: "feature/foo"
    )
    let expected = URL(filePath: "/tmp/base/feature_foo", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(resolved == expected)
  }

  @Test func resolvedWorktreeDirectoryUsesPathOverrideWithBranchLeaf() {
    let resolved = Tty7Paths.resolvedWorktreeDirectory(
      defaultBaseDirectory: URL(filePath: "/tmp/base", directoryHint: .isDirectory),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      nameOverride: nil,
      pathOverride: "/tmp/elsewhere",
      branchName: "feature_foo"
    )
    let expected = URL(filePath: "/tmp/elsewhere/feature_foo", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(resolved == expected)
  }

  @Test func resolvedWorktreeDirectoryCombinesNameAndPathOverrides() {
    let resolved = Tty7Paths.resolvedWorktreeDirectory(
      defaultBaseDirectory: URL(filePath: "/tmp/base", directoryHint: .isDirectory),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      nameOverride: "feature_foo",
      pathOverride: "~/Repos",
      branchName: "feature/foo"
    )
    let expected = URL(
      filePath: NSString(string: "~/Repos/feature_foo").expandingTildeInPath,
      directoryHint: .isDirectory
    )
    .standardizedFileURL

    #expect(resolved == expected)
  }

  @Test func previewWorktreeDirectoryFallsBackToBaseAndBranchWhenNoOverrides() {
    let preview = Tty7Paths.previewWorktreeDirectory(
      defaultBaseDirectory: URL(filePath: "/tmp/base", directoryHint: .isDirectory),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      nameOverride: nil,
      pathOverride: nil,
      branchName: "feature/foo"
    )
    let expected = URL(filePath: "/tmp/base/feature/foo", directoryHint: .isDirectory)
      .standardizedFileURL

    #expect(preview == expected)
  }

  @Test func previewWorktreeDirectoryReturnsBaseWhenBranchEmptyAndNoOverrides() {
    let preview = Tty7Paths.previewWorktreeDirectory(
      defaultBaseDirectory: URL(filePath: "/tmp/base", directoryHint: .isDirectory),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      nameOverride: nil,
      pathOverride: nil,
      branchName: ""
    )
    let expected = URL(filePath: "/tmp/base", directoryHint: .isDirectory).standardizedFileURL

    #expect(preview == expected)
  }
}
