import AppKit
import Foundation

@MainActor
@Observable
final class WorktreeDiffState {
  let worktree: Worktree
  private(set) var entries: [GitDiffEntry] = []
  private(set) var attributedDiff: NSAttributedString?
  private(set) var isLoading = false
  private var renderNonce: UUID?
  private let shell: ShellClient

  var onEntriesChanged: (([GitDiffEntry]) -> Void)?
  var onLoadingChanged: ((Bool) -> Void)?

  nonisolated init(worktree: Worktree, shell: ShellClient) {
    self.worktree = worktree
    self.shell = shell
  }

  convenience init(worktree: Worktree) {
    self.init(worktree: worktree, shell: .liveValue)
  }

  func refresh() {
    let worktreeURL = worktree.workingDirectory
    let nonce = UUID()
    renderNonce = nonce
    isLoading = true
    onLoadingChanged?(true)
    let shell = self.shell
    let appearance = NSApp.effectiveAppearance

    Task.detached { [weak self] in
      let path = worktreeURL.path(percentEncoded: false)
      let env = URL(fileURLWithPath: "/usr/bin/env")

      async let statusResult = Self.runGit(
        shell: shell, env: env,
        arguments: [
          "git", "-C", path, "status", "--porcelain=v1", "-z",
        ])
      async let numstatResult = Self.runGit(
        shell: shell, env: env,
        arguments: [
          "git", "-C", path, "diff", "HEAD", "--numstat",
        ])
      async let diffResult = Self.runGit(
        shell: shell, env: env,
        arguments: [
          "git", "-C", path, "diff", "HEAD",
        ])

      let statusOutput = (try? await statusResult) ?? ""
      let numstatOutput = (try? await numstatResult) ?? ""
      let diffOutput = (try? await diffResult) ?? ""

      let rawEntries = DiffParser.parseStatusPorcelain(statusOutput)
      let numstat = DiffParser.parseNumstat(numstatOutput)
      let entries = DiffParser.enrichEntries(rawEntries, with: numstat)
      nonisolated(unsafe) let attributed = DiffSyntaxHighlighter.highlight(
        diffText: diffOutput,
        appearance: appearance
      )

      await MainActor.run { [weak self] in
        guard let self, self.renderNonce == nonce else { return }
        self.entries = entries
        self.attributedDiff = attributed
        self.isLoading = false
        self.onEntriesChanged?(entries)
        self.onLoadingChanged?(false)
      }
    }
  }

  nonisolated private static func runGit(
    shell: ShellClient,
    env: URL,
    arguments: [String]
  ) async throws -> String {
    try await shell.run(env, arguments, nil).stdout
  }
}
