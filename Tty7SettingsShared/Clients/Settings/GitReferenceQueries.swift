import Foundation

private nonisolated let gitReferenceLogger = SupaLogger("Git")

/// Local + per-remote branch lists for the new-worktree base-ref picker.
public nonisolated struct GitBranchInventory: Sendable, Equatable {
  public var localBranches: [String]
  public var remotes: [GitRemoteBranchGroup]

  public init(localBranches: [String] = [], remotes: [GitRemoteBranchGroup] = []) {
    self.localBranches = localBranches
    self.remotes = remotes
  }

  public var isEmpty: Bool {
    localBranches.isEmpty && remotes.allSatisfy(\.branches.isEmpty)
  }

  /// Whether `ref` is a selectable branch in this inventory, matching the refs
  /// the base-ref menu renders (`main` locally, `origin/main` per remote).
  public func contains(ref: String) -> Bool {
    if localBranches.contains(ref) {
      return true
    }
    return remotes.contains { group in
      group.branches.contains { "\(group.name)/\($0)" == ref }
    }
  }
}

/// Branches belonging to a single remote, names stripped of the `remote/` prefix.
public nonisolated struct GitRemoteBranchGroup: Sendable, Equatable, Identifiable {
  public var name: String
  public var branches: [String]

  public var id: String { name }

  public init(name: String, branches: [String]) {
    self.name = name
    self.branches = branches
  }
}

public nonisolated struct GitReferenceQueries: Sendable {
  private let shell: ShellClient

  public init(shell: ShellClient = .live) {
    self.shell = shell
  }

  public func isBareRepository(for repoRoot: URL) async throws -> Bool {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "rev-parse",
        "--is-bare-repository",
      ]
    )
    return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }

  public func branchRefs(for repoRoot: URL) async throws -> [String] {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "for-each-ref",
        "--format=%(refname:short)\t%(upstream:short)",
        "refs/heads",
      ]
    )
    let refs = parseLocalRefsWithUpstream(output)
      .filter { !$0.hasSuffix("/HEAD") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return deduplicated(refs)
  }

  /// Local branches plus per-remote branch lists, each sorted alphabetically.
  /// Takes the already-resolved `remoteNames` so the caller's earlier
  /// `git remote` (used for the immediate quick picks) isn't run twice.
  public func branchInventory(for repoRoot: URL, remoteNames: [String]) async throws -> GitBranchInventory {
    async let localTask = orderedLocalBranchNames(for: repoRoot)
    async let remoteRefsTask = remoteBranchRefs(for: repoRoot)
    let (local, remoteRefs) = try await (localTask, remoteRefsTask)
    return GitBranchInventory(
      localBranches: Self.sortedAlphabetically(local),
      remotes: Self.groupRemoteBranches(refs: remoteRefs, remoteNames: remoteNames)
    )
  }

  /// Local branch names, case preserved, in declaration order. Named distinctly
  /// from `GitClient.localBranchNames` (a lowercased `Set` for membership checks)
  /// so the ordered-list-vs-set contract isn't conflated at a call site.
  public func orderedLocalBranchNames(for repoRoot: URL) async throws -> [String] {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/heads",
      ]
    )
    return Self.nonEmptyLines(output)
  }

  /// Full remote-tracking refs (e.g. `origin/main`), excluding `*/HEAD`.
  public func remoteBranchRefs(for repoRoot: URL) async throws -> [String] {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/remotes",
      ]
    )
    return Self.nonEmptyLines(output).filter { !$0.hasSuffix("/HEAD") }
  }

  public func remoteNames(for repoRoot: URL) async throws -> [String] {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "remote",
      ]
    )
    return Self.nonEmptyLines(output)
  }

  /// Local branch name for a remote ref (`origin/main` -> `main`), or nil when
  /// the ref isn't owned by one of the known remotes.
  public static func localBranchName(fromRemoteRef ref: String, remoteNames: [String]) -> String? {
    remotePrefixMatch(ref: ref, remoteNames: remoteNames)?.branch
  }

  /// Single source of truth for stripping a `<remote>/` prefix. Tries the
  /// longest remote name first so a remote whose name is a prefix of another
  /// (e.g. `up` vs `upstream`) matches the right one.
  public static func remotePrefixMatch(ref: String, remoteNames: [String]) -> (remote: String, branch: String)? {
    for remote in remoteNames.sorted(by: { $0.count > $1.count }) {
      let prefix = "\(remote)/"
      guard ref.hasPrefix(prefix) else { continue }
      let branch = String(ref.dropFirst(prefix.count))
      return branch.isEmpty ? nil : (remote, branch)
    }
    return nil
  }

  static func groupRemoteBranches(refs: [String], remoteNames: [String]) -> [GitRemoteBranchGroup] {
    var grouped: [String: [String]] = [:]
    for ref in refs {
      guard let match = remotePrefixMatch(ref: ref, remoteNames: remoteNames) else { continue }
      grouped[match.remote, default: []].append(match.branch)
    }
    // `origin` first, then the remaining remotes alphabetically.
    return
      remoteNames
      .sorted { lhs, rhs in
        if lhs == "origin" { return rhs != "origin" }
        if rhs == "origin" { return false }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
      }
      .compactMap { remote in
        guard let branches = grouped[remote] else { return nil }
        return GitRemoteBranchGroup(name: remote, branches: sortedAlphabetically(branches))
      }
  }

  private static func nonEmptyLines(_ output: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func sortedAlphabetically(_ values: [String]) -> [String] {
    values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  public func defaultRemoteBranchRef(for repoRoot: URL) async throws -> String? {
    do {
      let output = try await runGit(
        arguments: [
          "-C",
          repoRoot.path(percentEncoded: false),
          "symbolic-ref",
          "-q",
          "refs/remotes/origin/HEAD",
        ]
      )
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if let resolved = Self.normalizeRemoteRef(trimmed),
        await refExists(resolved, repoRoot: repoRoot)
      {
        return resolved
      }
    } catch {
      gitReferenceLogger.warning(
        "Default remote branch ref failed for \(repoRoot.path(percentEncoded: false)): \(error.localizedDescription)"
      )
    }
    let fallback = "origin/main"
    if await refExists(fallback, repoRoot: repoRoot) {
      return fallback
    }
    return nil
  }

  public func automaticWorktreeBaseRef(for repoRoot: URL) async -> String? {
    let remote = try? await defaultRemoteBranchRef(for: repoRoot)
    if let remote {
      return Self.preferredBaseRef(remote: remote, localHead: nil)
    }
    let localHead = try? await localHeadBranchRef(for: repoRoot)
    let resolvedLocalHead = await resolveLocalHead(localHead, repoRoot: repoRoot)
    return Self.preferredBaseRef(remote: nil, localHead: resolvedLocalHead)
  }

  public static func preferredBaseRef(remote: String?, localHead: String?) -> String? {
    remote ?? localHead
  }

  private func runGit(arguments: [String]) async throws -> String {
    try await shell.run(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments, nil).stdout
  }

  private func parseLocalRefsWithUpstream(_ output: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .compactMap { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let local = parts.first else {
          return nil
        }
        let localRef = String(local).trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRef =
          parts.count > 1
          ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
          : ""
        if !upstreamRef.isEmpty {
          return upstreamRef
        }
        return localRef.isEmpty ? nil : localRef
      }
  }

  private func deduplicated(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func normalizeRemoteRef(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let prefix = "refs/remotes/"
    if trimmed.hasPrefix(prefix) {
      return String(trimmed.dropFirst(prefix.count))
    }
    return trimmed
  }

  private func localHeadBranchRef(for repoRoot: URL) async throws -> String? {
    let output = try await runGit(
      arguments: [
        "-C",
        repoRoot.path(percentEncoded: false),
        "symbolic-ref",
        "--short",
        "HEAD",
      ]
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolveLocalHead(_ localHead: String?, repoRoot: URL) async -> String? {
    guard let localHead else {
      return nil
    }
    if await refExists(localHead, repoRoot: repoRoot) {
      return localHead
    }
    return nil
  }

  private func refExists(_ ref: String, repoRoot: URL) async -> Bool {
    do {
      _ = try await runGit(
        arguments: [
          "-C",
          repoRoot.path(percentEncoded: false),
          "rev-parse",
          "--verify",
          "--quiet",
          ref,
        ]
      )
      return true
    } catch {
      return false
    }
  }
}
