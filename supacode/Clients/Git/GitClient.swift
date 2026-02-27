import Foundation
import Sentry

enum GitOperation: String {
  case repoRoot = "repo_root"
  case worktreeList = "worktree_list"
  case worktreeCreate = "worktree_create"
  case worktreeRemove = "worktree_remove"
  case worktreePrune = "worktree_prune"
  case repoIsBare = "repo_is_bare"
  case branchNames = "branch_names"
  case branchNameValidation = "branch_name_validation"
  case branchRefs = "branch_refs"
  case defaultRemoteBranchRef = "default_remote_branch_ref"
  case localHeadRef = "local_head_ref"
  case ignoredFileCount = "ignored_file_count"
  case untrackedFileCount = "untracked_file_count"
  case branchRename = "branch_rename"
  case branchDelete = "branch_delete"
  case lineChanges = "line_changes"
  case remoteInfo = "remote_info"
}

enum GitClientError: LocalizedError {
  case commandFailed(command: String, message: String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let command, let message):
      if message.isEmpty {
        return "Git command failed: \(command)"
      }
      return "Git command failed: \(command)\n\(message)"
    }
  }
}

enum GitWorktreeCreateEvent: Equatable, Sendable {
  case outputLine(ShellStreamLine)
  case finished(Worktree)
}

struct GitClient {
  private struct WorktreeSortEntry {
    let worktree: Worktree
    let createdAt: Date
    let index: Int
  }

  private let shell: ShellClient

  nonisolated init(shell: ShellClient = .live) {
    self.shell = shell
  }

  nonisolated func repoRoot(for path: URL) async throws -> URL {
    let normalizedPath = Self.directoryURL(for: path)
    let wtURL = try wtScriptURL()
    let output = try await runLoginShellProcess(
      operation: .repoRoot,
      executableURL: wtURL,
      arguments: ["root"],
      currentDirectoryURL: normalizedPath
    )
    if output.isEmpty {
      let command = "\(wtURL.lastPathComponent) root"
      throw GitClientError.commandFailed(command: command, message: "Empty output")
    }
    return URL(fileURLWithPath: output).standardizedFileURL
  }

  nonisolated func worktrees(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let output = try await runWtList(repoRoot: repoRoot)
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return []
    }
    let data = Data(trimmed.utf8)
    let entries = try JSONDecoder().decode([GitWtWorktreeEntry].self, from: data)
      .filter { !$0.isBare }
    let worktreeEntries = entries.enumerated().map { index, entry in
      let worktreeURL = URL(fileURLWithPath: entry.path).standardizedFileURL
      let name = entry.branch.isEmpty ? worktreeURL.lastPathComponent : entry.branch
      let detail = Self.relativePath(from: repositoryRootURL, to: worktreeURL)
      let id = worktreeURL.path(percentEncoded: false)
      let resourceValues = try? worktreeURL.resourceValues(forKeys: [
        .creationDateKey, .contentModificationDateKey,
      ])
      let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
      let sortDate = createdAt ?? .distantPast
      return WorktreeSortEntry(
        worktree: Worktree(
          id: id,
          name: name,
          detail: detail,
          workingDirectory: worktreeURL,
          repositoryRootURL: repositoryRootURL,
          createdAt: createdAt
        ),
        createdAt: sortDate,
        index: index
      )
    }
    return
      worktreeEntries
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt > rhs.createdAt
        }
        return lhs.index < rhs.index
      }
      .map(\.worktree)
  }

  nonisolated func pruneWorktrees(for repoRoot: URL) async throws {
    let path = repoRoot.path(percentEncoded: false)
    _ = try await runGit(
      operation: .worktreePrune,
      arguments: ["-C", path, "worktree", "prune"]
    )
  }

  nonisolated func localBranchNames(for repoRoot: URL) async throws -> Set<String> {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .branchNames,
      arguments: [
        "-C",
        path,
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/heads",
      ]
    )
    let names =
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    return Set(names)
  }

  nonisolated func isValidBranchName(_ branchName: String, for repoRoot: URL) async -> Bool {
    let path = repoRoot.path(percentEncoded: false)
    do {
      _ = try await runGit(
        operation: .branchNameValidation,
        arguments: ["-C", path, "check-ref-format", "--branch", branchName]
      )
      return true
    } catch {
      return false
    }
  }

  nonisolated func isBareRepository(for repoRoot: URL) async throws -> Bool {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .repoIsBare,
      arguments: ["-C", path, "rev-parse", "--is-bare-repository"]
    )
    return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }

  nonisolated func branchRefs(for repoRoot: URL) async throws -> [String] {
    let path = repoRoot.path(percentEncoded: false)
    let localOutput = try await runGit(
      operation: .branchRefs,
      arguments: [
        "-C",
        path,
        "for-each-ref",
        "--format=%(refname:short)\t%(upstream:short)",
        "refs/heads",
      ]
    )
    let refs = parseLocalRefsWithUpstream(localOutput)
      .filter { !$0.hasSuffix("/HEAD") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return deduplicated(refs)
  }

  nonisolated func defaultRemoteBranchRef(for repoRoot: URL) async throws -> String? {
    let path = repoRoot.path(percentEncoded: false)
    do {
      let output = try await runGit(
        operation: .defaultRemoteBranchRef,
        arguments: ["-C", path, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"]
      )
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if let resolved = normalizeRemoteRef(trimmed),
        await refExists(resolved, repoRoot: repoRoot)
      {
        return resolved
      }
    } catch {
      let rootPath = repoRoot.path(percentEncoded: false)
      gitLogger.warning(
        "Default remote branch ref failed for \(rootPath): \(error.localizedDescription)"
      )
    }
    let fallback = "origin/main"
    if await refExists(fallback, repoRoot: repoRoot) {
      return fallback
    }
    return nil
  }

  nonisolated func automaticWorktreeBaseRef(for repoRoot: URL) async -> String? {
    let resolved = try? await defaultRemoteBranchRef(for: repoRoot)
    if let resolved {
      return Self.preferredBaseRef(remote: resolved, localHead: nil)
    }
    let localHead = try? await localHeadBranchRef(for: repoRoot)
    let resolvedLocalHead = await resolveLocalHead(localHead, repoRoot: repoRoot)
    return Self.preferredBaseRef(remote: nil, localHead: resolvedLocalHead)
  }

  nonisolated func ignoredFileCount(for repoRoot: URL) async throws -> Int {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .ignoredFileCount,
      arguments: ["-C", path, "ls-files", "--others", "-i", "--exclude-standard"]
    )
    return parseFileListCount(output)
  }

  nonisolated func untrackedFileCount(for repoRoot: URL) async throws -> Int {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .untrackedFileCount,
      arguments: ["-C", path, "ls-files", "--others", "--exclude-standard"]
    )
    return parseFileListCount(output)
  }

  nonisolated func createWorktree(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String
  ) async throws -> Worktree {
    var createdWorktree: Worktree?
    for try await event in createWorktreeStream(
      named: name,
      in: repoRoot,
      baseDirectory: baseDirectory,
      copyFiles: copyFiles,
      baseRef: baseRef
    ) {
      if case .finished(let worktree) = event {
        createdWorktree = worktree
      }
    }
    guard let createdWorktree else {
      let wtURL = try wtScriptURL()
      let command =
        ([wtURL.lastPathComponent]
        + createWorktreeArguments(
          baseDirectory: baseDirectory,
          name: name,
          copyIgnored: copyFiles.ignored,
          copyUntracked: copyFiles.untracked,
          baseRef: baseRef
        )).joined(separator: " ")
      throw GitClientError.commandFailed(command: command, message: "Empty output")
    }
    return createdWorktree
  }

  nonisolated func createWorktreeStream(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        let repositoryRootURL = repoRoot.standardizedFileURL
        do {
          let wtURL = try wtScriptURL()
          let arguments = createWorktreeArguments(
            baseDirectory: baseDirectory,
            name: name,
            copyIgnored: copyFiles.ignored,
            copyUntracked: copyFiles.untracked,
            baseRef: baseRef
          )
          let envURL = URL(fileURLWithPath: "/usr/bin/env")
          let localeArguments = ["LANG=C", "LC_ALL=C", "LC_MESSAGES=C"]
          let invocationArguments = localeArguments + [wtURL.path(percentEncoded: false)] + arguments
          let command = ([envURL.path(percentEncoded: false)] + invocationArguments).joined(separator: " ")
          var pathLine: String?
          do {
            for try await streamEvent in shell.runLoginStream(
              envURL,
              invocationArguments,
              repoRoot
            ) {
              switch streamEvent {
              case .line(let line):
                continuation.yield(.outputLine(line))
                if line.source == .stdout {
                  let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                  if !trimmed.isEmpty {
                    pathLine = trimmed
                  }
                }
              case .finished(let output):
                if pathLine == nil {
                  pathLine = lastNonEmptyLine(in: output.stdout)
                }
                guard let pathLine else {
                  throw GitClientError.commandFailed(command: command, message: "Empty output")
                }
                let worktreeURL = URL(fileURLWithPath: pathLine).standardizedFileURL
                let detail = Self.relativePath(from: repositoryRootURL, to: worktreeURL)
                let id = worktreeURL.path(percentEncoded: false)
                let resourceValues = try? worktreeURL.resourceValues(forKeys: [
                  .creationDateKey, .contentModificationDateKey,
                ])
                let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
                let worktree = Worktree(
                  id: id,
                  name: name,
                  detail: detail,
                  workingDirectory: worktreeURL,
                  repositoryRootURL: repositoryRootURL,
                  createdAt: createdAt
                )
                continuation.yield(.finished(worktree))
                continuation.finish()
                return
              }
            }
            continuation.finish(throwing: GitClientError.commandFailed(command: command, message: "Empty output"))
          } catch {
            if let gitError = error as? GitClientError {
              continuation.finish(throwing: gitError)
            } else {
              continuation.finish(
                throwing: wrapShellError(error, operation: .worktreeCreate, command: command)
              )
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  nonisolated private func createWorktreeArguments(
    baseDirectory: URL,
    name: String,
    copyIgnored: Bool,
    copyUntracked: Bool,
    baseRef: String
  ) -> [String] {
    var arguments = ["--base-dir", baseDirectory.path(percentEncoded: false), "sw"]
    if copyIgnored {
      arguments.append("--copy-ignored")
    }
    if copyUntracked {
      arguments.append("--copy-untracked")
    }
    if !baseRef.isEmpty {
      arguments.append("--from")
      arguments.append(baseRef)
    }
    if copyIgnored || copyUntracked {
      arguments.append("--verbose")
    }
    arguments.append(name)
    return arguments
  }

  nonisolated func renameBranch(in worktreeURL: URL, to branchName: String) async throws {
    let path = worktreeURL.path(percentEncoded: false)
    _ = try await runGit(
      operation: .branchRename,
      arguments: ["-C", path, "branch", "-m", branchName]
    )
  }

  nonisolated func branchName(for worktreeURL: URL) async -> String? {
    let headURL = await MainActor.run {
      GitWorktreeHeadResolver.headURL(
        for: worktreeURL,
        fileManager: .default
      )
    }
    guard let headURL else {
      return nil
    }
    guard
      let line = try? String(contentsOf: headURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .first
    else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let refPrefix = "ref:"
    if trimmed.hasPrefix(refPrefix) {
      let ref = trimmed.dropFirst(refPrefix.count).trimmingCharacters(in: .whitespaces)
      let headsPrefix = "refs/heads/"
      if ref.hasPrefix(headsPrefix) {
        return String(ref.dropFirst(headsPrefix.count))
      }
      return String(ref)
    }
    return "HEAD"
  }

  nonisolated func lineChanges(at worktreeURL: URL) async -> (added: Int, removed: Int)? {
    if await isWorktreeIndexLocked(worktreeURL) {
      return nil
    }
    let path = worktreeURL.path(percentEncoded: false)
    do {
      let diff = try await runGit(
        operation: .lineChanges,
        arguments: ["-C", path, "diff", "HEAD", "--shortstat"]
      )
      let changes = parseShortstat(diff)
      return (added: changes.added, removed: changes.removed)
    } catch {
      return nil
    }
  }

  nonisolated private func isWorktreeIndexLocked(_ worktreeURL: URL) async -> Bool {
    let headURL = await MainActor.run {
      GitWorktreeHeadResolver.headURL(
        for: worktreeURL,
        fileManager: .default
      )
    }
    guard let headURL else {
      return false
    }
    let gitDirectory = headURL.deletingLastPathComponent()
    let lockURL = gitDirectory.appending(path: "index.lock")
    return FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false))
  }

  nonisolated func remoteInfo(for repositoryRoot: URL) async -> GithubRemoteInfo? {
    let path = repositoryRoot.path(percentEncoded: false)
    guard
      let remotesOutput = try? await runGit(
        operation: .remoteInfo,
        arguments: ["-C", path, "remote"]
      )
    else {
      return nil
    }
    let remotes =
      remotesOutput
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let orderedRemotes: [String]
    if remotes.contains("origin") {
      orderedRemotes = ["origin"] + remotes.filter { $0 != "origin" }
    } else {
      orderedRemotes = remotes
    }
    for remote in orderedRemotes {
      guard
        let remoteURL = try? await runGit(
          operation: .remoteInfo,
          arguments: ["-C", path, "remote", "get-url", remote]
        )
      else {
        continue
      }
      if let info = Self.parseGithubRemoteInfo(remoteURL) {
        return info
      }
    }
    return nil
  }

  nonisolated func removeWorktree(_ worktree: Worktree, deleteBranch: Bool) async throws -> URL {
    let rootPath = worktree.repositoryRootURL.path(percentEncoded: false)
    let worktreeURL = worktree.workingDirectory.standardizedFileURL
    let worktreePath = worktreeURL.path(percentEncoded: false)
    let relocatedURL = Self.relocateWorktreeDirectory(worktreeURL)
    if let relocatedURL {
      do {
        _ = try await runGit(
          operation: .worktreePrune,
          arguments: ["-C", rootPath, "worktree", "prune", "--expire=now"]
        )
      } catch {
        await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
      }
      if deleteBranch, !worktree.name.isEmpty {
        let names = try await localBranchNames(for: worktree.repositoryRootURL)
        if names.contains(worktree.name.lowercased()) {
          _ = try? await runGit(
            operation: .branchDelete,
            arguments: ["-C", rootPath, "branch", "-D", worktree.name]
          )
        }
      }
      Task.detached {
        try? FileManager.default.removeItem(at: relocatedURL)
      }
      return worktree.workingDirectory
    }
    await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
    if deleteBranch, !worktree.name.isEmpty {
      let names = try await localBranchNames(for: worktree.repositoryRootURL)
      if names.contains(worktree.name.lowercased()) {
        _ = try? await runGit(
          operation: .branchDelete,
          arguments: ["-C", rootPath, "branch", "-D", worktree.name]
        )
      }
    }
    return worktree.workingDirectory
  }

  nonisolated private func parseShortstat(_ output: String) -> (added: Int, removed: Int) {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (0, 0)
    }
    var added = 0
    var removed = 0
    if let match = trimmed.firstMatch(of: /(\d+)\s+insertions?\(\+\)/) {
      added = Int(match.1) ?? 0
    }
    if let match = trimmed.firstMatch(of: /(\d+)\s+deletions?\(-\)/) {
      removed = Int(match.1) ?? 0
    }
    return (added, removed)
  }

  nonisolated private func parseFileListCount(_ output: String) -> Int {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .count
  }

  nonisolated private func lastNonEmptyLine(in output: String) -> String? {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
  }

  nonisolated private func parseLocalRefsWithUpstream(_ output: String) -> [String] {
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

  nonisolated private func deduplicated(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  nonisolated private func normalizeRemoteRef(_ value: String) -> String? {
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

  nonisolated private func localHeadBranchRef(for repoRoot: URL) async throws -> String? {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .localHeadRef,
      arguments: ["-C", path, "symbolic-ref", "--short", "HEAD"]
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  nonisolated private func resolveLocalHead(_ localHead: String?, repoRoot: URL) async -> String? {
    guard let localHead else { return nil }
    if await refExists(localHead, repoRoot: repoRoot) {
      return localHead
    }
    return nil
  }

  nonisolated static func preferredBaseRef(remote: String?, localHead: String?) -> String? {
    remote ?? localHead
  }

  nonisolated private func refExists(_ ref: String, repoRoot: URL) async -> Bool {
    let path = repoRoot.path(percentEncoded: false)
    do {
      _ = try await runGit(
        operation: .defaultRemoteBranchRef,
        arguments: ["-C", path, "rev-parse", "--verify", "--quiet", ref]
      )
      return true
    } catch {
      return false
    }
  }

  nonisolated private func runGit(
    operation: GitOperation,
    arguments: [String]
  ) async throws -> String {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    let command = ([env.path(percentEncoded: false)] + ["git"] + arguments).joined(separator: " ")
    do {
      return try await shell.run(env, ["git"] + arguments, nil).stdout
    } catch {
      throw wrapShellError(error, operation: operation, command: command)
    }
  }

  nonisolated private func runWtList(repoRoot: URL) async throws -> String {
    let wtURL = try wtScriptURL()
    let arguments = ["ls", "--json"]
    return try await runLoginShellProcess(
      operation: .worktreeList,
      executableURL: wtURL,
      arguments: arguments,
      currentDirectoryURL: repoRoot
    )
  }

  nonisolated private func wtScriptURL() throws -> URL {
    guard let url = Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt") else {
      fatalError("Bundled wt script not found")
    }
    return url
  }

  nonisolated private func runLoginShellProcess(
    operation: GitOperation,
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?
  ) async throws -> String {
    let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
    do {
      return try await shell.runLogin(executableURL, arguments, currentDirectoryURL).stdout
    } catch {
      throw wrapShellError(error, operation: operation, command: command)
    }
  }

  nonisolated private static func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var index = 0
    while index < min(baseComponents.count, targetComponents.count),
      baseComponents[index] == targetComponents[index]
    {
      index += 1
    }
    var result: [String] = []
    if index < baseComponents.count {
      result.append(contentsOf: Array(repeating: "..", count: baseComponents.count - index))
    }
    if index < targetComponents.count {
      result.append(contentsOf: targetComponents[index...])
    }
    if result.isEmpty {
      return "."
    }
    return result.joined(separator: "/")
  }

  nonisolated private static func directoryURL(for path: URL) -> URL {
    if path.hasDirectoryPath {
      return path
    }
    return path.deletingLastPathComponent()
  }

  nonisolated private func runGitWorktreeRemove(
    rootPath: String,
    worktreePath: String
  ) async {
    _ = try? await runGit(
      operation: .worktreeRemove,
      arguments: [
        "-C",
        rootPath,
        "worktree",
        "remove",
        "--force",
        worktreePath,
      ]
    )
  }

  nonisolated private static func relocateWorktreeDirectory(_ worktreeURL: URL) -> URL? {
    let fileManager = FileManager.default
    let worktreePath = worktreeURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: worktreePath) else {
      return nil
    }
    let candidates = [
      URL(filePath: "/tmp", directoryHint: .isDirectory),
      fileManager.temporaryDirectory,
    ]
    for baseURL in candidates {
      let trashBaseURL = baseURL.appending(
        path: "supacode-worktree-trash",
        directoryHint: URL.DirectoryHint.isDirectory
      )
      do {
        try fileManager.createDirectory(at: trashBaseURL, withIntermediateDirectories: true)
      } catch {
        continue
      }
      let destinationURL = trashBaseURL.appending(
        path: "\(worktreeURL.lastPathComponent)-\(UUID().uuidString)",
        directoryHint: URL.DirectoryHint.isDirectory
      )
      do {
        try fileManager.moveItem(at: worktreeURL, to: destinationURL)
        return destinationURL
      } catch {
        continue
      }
    }
    return nil
  }

  nonisolated static func parseGithubRemoteInfo(_ remoteURL: String) -> GithubRemoteInfo? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    if trimmed.hasPrefix("git@") {
      let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else {
        return nil
      }
      let hostAndPath = parts[1]
      let hostParts = hostAndPath.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
      guard hostParts.count == 2 else {
        return nil
      }
      return parseGithubRemoteInfo(host: String(hostParts[0]), path: String(hostParts[1]))
    }
    guard let url = URL(string: trimmed), let host = url.host else {
      return nil
    }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return parseGithubRemoteInfo(host: host, path: path)
  }

  nonisolated private static func parseGithubRemoteInfo(host: String, path: String) -> GithubRemoteInfo? {
    let normalizedHost = host.lowercased()
    guard normalizedHost.contains("github") else {
      return nil
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2 else {
      return nil
    }
    let owner = String(components[0])
    var repo = String(components[1])
    if repo.hasSuffix(".git") {
      repo = String(repo.dropLast(4))
    }
    guard !owner.isEmpty, !repo.isEmpty else {
      return nil
    }
    return GithubRemoteInfo(host: host, owner: owner, repo: repo)
  }

}

private nonisolated let gitLogger = SupaLogger("Git")

nonisolated private func wrapShellError(
  _ error: Error,
  operation: GitOperation,
  command: String
) -> GitClientError {
  let gitError: GitClientError
  var exitCode: Int32 = -1
  if let shellError = error as? ShellClientError {
    exitCode = shellError.exitCode
    var messageParts: [String] = []
    if !shellError.stdout.isEmpty {
      messageParts.append("stdout:\n\(shellError.stdout)")
    }
    if !shellError.stderr.isEmpty {
      messageParts.append("stderr:\n\(shellError.stderr)")
    }
    let message = messageParts.joined(separator: "\n")
    gitError = .commandFailed(command: command, message: message)
  } else {
    gitError = .commandFailed(command: command, message: error.localizedDescription)
  }
  gitLogger.warning("git command failed operation=\(operation.rawValue) exit_code=\(exitCode)")
  #if !DEBUG
    SentrySDK.logger.error(
      "git command failed",
      attributes: [
        "operation": operation.rawValue,
        "exit_code": Int(exitCode),
      ]
    )
  #endif
  return gitError
}

struct GitWtWorktreeEntry: Decodable, Equatable {
  let branch: String
  let path: String
  let head: String
  let isBare: Bool

  enum CodingKeys: String, CodingKey {
    case branch
    case path
    case head
    case isBare = "is_bare"
  }

}
