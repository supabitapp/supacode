import ConcurrencyExtras
import Foundation
import Sentry
import SupacodeSettingsShared

enum GitOperation: String {
  case version = "version"
  case repoRoot = "repo_root"
  case worktreeList = "worktree_list"
  case worktreeCreate = "worktree_create"
  case worktreeRemove = "worktree_remove"
  case worktreePrune = "worktree_prune"
  case gitCommonDir = "git_common_dir"
  case repoIsBare = "repo_is_bare"
  case branchNames = "branch_names"
  case branchNameValidation = "branch_name_validation"
  case branchRefs = "branch_refs"
  case defaultRemoteBranchRef = "default_remote_branch_ref"
  case localHeadRef = "local_head_ref"
  case symbolicHeadRef = "symbolic_head_ref"
  case ignoredFileCount = "ignored_file_count"
  case untrackedFileCount = "untracked_file_count"
  case branchDelete = "branch_delete"
  case branchRename = "branch_rename"
  case lineChanges = "line_changes"
  case remoteInfo = "remote_info"
  case remoteList = "remote_list"
  case fetchOrigin = "fetch_origin"
  case clone = "clone"
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

enum GitCloneEvent: Equatable, Sendable {
  case outputLine(ShellStreamLine)
  case finished(directory: URL)
}

nonisolated struct WorktreeAdminEntry: Sendable {
  let adminDirectory: URL
  let worktreeDirectory: URL
  let lockReason: String?
}

// JSON payload written to `<git-common-dir>/worktrees/<name>/locked`
// for every worktree Supacode manages. Detection keys on `owner ==
// "supacode"`; the other fields are forensic so a stranded lock file
// can be traced back to a specific build.
nonisolated struct SupacodeWorktreeLockMetadata: Codable, Sendable, Equatable {
  let owner: String
  let version: String?
  let build: String?
  let createdAt: Int64?
}

struct GitClient {
  nonisolated static let supacodeLockOwner = "supacode"

  private struct WorktreeSortEntry {
    let worktree: Worktree
    let createdAt: Date
    let index: Int
  }

  private let shell: ShellClient
  private let referenceQueries: GitReferenceQueries

  nonisolated init(shell: ShellClient = .live) {
    self.shell = shell
    self.referenceQueries = GitReferenceQueries(shell: shell)
  }

  nonisolated func repoRoot(for path: URL) async throws -> URL {
    let normalizedPath = Self.directoryURL(for: path)
    let wtURL = try wtScriptURL()
    let output = try await runBundledWtProcess(
      operation: .repoRoot,
      executableURL: wtURL,
      arguments: ["root"],
      currentDirectoryURL: normalizedPath
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      let command = "\(wtURL.lastPathComponent) root"
      throw GitClientError.commandFailed(command: command, message: "Empty output")
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL
  }

  nonisolated func worktrees(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let output = try await runWtList(repoRoot: repoRoot)
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return []
    }
    let data = Data(trimmed.utf8)
    let fileManager = FileManager.default
    let entries = try JSONDecoder().decode([GitWtWorktreeEntry].self, from: data)
      .filter { !$0.isBare }
    let worktreeEntries = entries.enumerated().map { index, entry in
      let worktreeURL = URL(fileURLWithPath: entry.path).standardizedFileURL
      // Orphan signal: working dir is gone (lock state checked separately when reconciling).
      let isMissing = !fileManager.fileExists(atPath: entry.path)
      let isAttached = !entry.branch.isEmpty
      let name = isAttached ? entry.branch : worktreeURL.lastPathComponent
      let detail = Self.relativePath(from: repositoryRootURL, to: worktreeURL)
      let resourceValues = try? worktreeURL.resourceValues(forKeys: [
        .creationDateKey, .contentModificationDateKey,
      ])
      let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
      let sortDate = createdAt ?? .distantPast
      return WorktreeSortEntry(
        worktree: Worktree(
          location: .local(workingDirectory: worktreeURL, repositoryRoot: repositoryRootURL),
          kind: .git,
          name: name,
          detail: detail,
          createdAt: createdAt,
          isMissing: isMissing,
          isAttached: isAttached
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

  /// Worktrees via standard `git worktree list --porcelain`. Used for remote
  /// (SSH) repositories where the bundled `wt` shim isn't available; the only
  /// requirement is `git` on the remote PATH. Returns the same `Worktree`
  /// shape as `worktrees(for:)`; the caller injects `host` / host-keyed ids.
  /// Remote paths can't be stat'd locally, so `isMissing` is always false and
  /// there's no creation-date sort (git's listing order is kept, main first).
  nonisolated func gitWorktrees(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let output = try await runGit(
      operation: .worktreeList,
      arguments: ["-C", repositoryRootURL.path(percentEncoded: false), "worktree", "list", "--porcelain"]
    )
    return Self.parseWorktreePorcelain(output, repositoryRootURL: repositoryRootURL)
  }

  /// Parse `git worktree list --porcelain`: blank-line-separated blocks of
  /// `worktree <path>` / `HEAD <sha>` / `branch refs/heads/<name>` (or
  /// `detached`); a `bare` block for the bare root is skipped.
  nonisolated static func parseWorktreePorcelain(
    _ output: String,
    repositoryRootURL: URL
  ) -> [Worktree] {
    var worktrees: [Worktree] = []
    for block in output.components(separatedBy: "\n\n") {
      var path: String?
      var branch: String?
      var isBare = false
      var isDetached = false
      for rawLine in block.split(whereSeparator: \.isNewline) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("worktree ") {
          path = String(line.dropFirst("worktree ".count))
        } else if line.hasPrefix("branch ") {
          let ref = String(line.dropFirst("branch ".count))
          let headsPrefix = "refs/heads/"
          branch = ref.hasPrefix(headsPrefix) ? String(ref.dropFirst(headsPrefix.count)) : ref
        } else if line == "bare" {
          isBare = true
        } else if line == "detached" {
          isDetached = true
        }
      }
      guard let path, !path.isEmpty, !isBare else { continue }
      let worktreeURL = URL(fileURLWithPath: path).standardizedFileURL
      let isAttached = (branch != nil) && !isDetached
      let name = isAttached ? (branch ?? worktreeURL.lastPathComponent) : worktreeURL.lastPathComponent
      worktrees.append(
        Worktree(
          location: .local(workingDirectory: worktreeURL, repositoryRoot: repositoryRootURL),
          kind: .git,
          name: name,
          detail: relativePath(from: repositoryRootURL, to: worktreeURL),
          createdAt: nil,
          isMissing: false,
          isAttached: isAttached
        )
      )
    }
    return worktrees
  }

  /// Create a worktree via standard `git worktree add` (for remote repos where
  /// the bundled `wt` shim isn't available). Creates a new branch `name` at
  /// `worktreePath` from `baseRef` (omitted → current HEAD). Throws
  /// `GitClientError` on failure (collision, bad ref, missing parent dir).
  /// Callers typically reload to re-list over ssh rather than build a worktree
  /// model from this directly.
  nonisolated func createGitWorktree(
    in repoRoot: URL,
    name: String,
    baseRef: String,
    worktreePath: URL
  ) async throws {
    let rootPath = repoRoot.standardizedFileURL.path(percentEncoded: false)
    let wtPath = worktreePath.standardizedFileURL.path(percentEncoded: false)
    var arguments = ["-C", rootPath, "worktree", "add", wtPath, "-b", name]
    if !baseRef.isEmpty {
      arguments.append(baseRef)
    }
    _ = try await runGit(operation: .worktreeCreate, arguments: arguments)
  }

  // Backfill-only, with one exception: a worktree whose `.git` link is broken
  // has its Supacode lock released so the prune can reclaim the orphan (#616).
  // Every other Supacode-owned lock is left intact; `removeWorktree` is the
  // normal release path.
  nonisolated func reconcileSupacodeLocks(for repoRoot: URL) async {
    // Folder-kind roots have no git admin dir; skip the shell-outs.
    guard Repository.isGitRepository(at: repoRoot) else { return }
    let entries: [WorktreeAdminEntry]
    do {
      entries = try await worktreeAdminEntries(for: repoRoot)
    } catch {
      gitLogger.warning(
        "Failed to enumerate admin entries for \(repoRoot.lastPathComponent): \(error)"
      )
      return
    }
    let fileManager = FileManager.default
    for entry in entries {
      let exists = fileManager.fileExists(
        atPath: entry.worktreeDirectory.path(percentEncoded: false)
      )
      // A worktree whose `.git` link is gone is an orphan git can't use, yet its
      // path resolves up to the repo root and shadows the main worktree (#616).
      // Release our own lock (checked before the `lockReason` guard, since the
      // orphan is already locked) so the prune below reclaims it. `exists` gates
      // this so a transiently missing worktree keeps its lock (#338).
      if exists, Self.isGitdirLinkBroken(worktreeDirectory: entry.worktreeDirectory) {
        let name = entry.worktreeDirectory.lastPathComponent
        switch Self.removeSupacodeLock(at: entry.adminDirectory) {
        case .removed:
          gitLogger.info("Released Supacode lock on broken worktree \(name)")
        case .keptForeignLock:
          // A user `git worktree lock --reason` orphan is never reclaimed here, so
          // flag it rather than let the prune silently skip it.
          gitLogger.warning("Broken worktree \(name) keeps a user lock; prune cannot reclaim it")
        case .failed(let error):
          gitLogger.warning("Failed to release Supacode lock on broken worktree \(name): \(error)")
        case .notPresent:
          break
        }
        continue
      }
      guard entry.lockReason == nil else { continue }
      guard exists else { continue }
      Self.writeSupacodeLock(at: entry.adminDirectory)
      gitLogger.info(
        "Backfilled Supacode lock for worktree \(entry.worktreeDirectory.lastPathComponent)"
      )
    }
    do {
      _ = try await runGit(
        operation: .worktreePrune,
        arguments: ["-C", repoRoot.path(percentEncoded: false), "worktree", "prune"]
      )
    } catch {
      gitLogger.warning(
        "Reconcile prune failed for \(repoRoot.lastPathComponent): \(error)"
      )
    }
  }

  nonisolated func gitCommonDirectory(for repoRoot: URL) async throws -> URL {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .gitCommonDir,
      arguments: ["-C", path, "rev-parse", "--git-common-dir"]
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw GitClientError.commandFailed(
        command: "git rev-parse --git-common-dir",
        message: "Empty output"
      )
    }
    // `URL(fileURLWithPath:relativeTo:)` drops the leaf when the base
    // URL doesn't carry `hasDirectoryPath`. Compose explicitly so the
    // resolution doesn't depend on Foundation's disk probe.
    let base = URL(filePath: repoRoot.path(percentEncoded: false), directoryHint: .isDirectory)
    let resolved =
      trimmed.hasPrefix("/")
      ? URL(filePath: trimmed, directoryHint: .isDirectory)
      : base.appending(path: trimmed, directoryHint: .isDirectory)
    return resolved.standardizedFileURL
  }

  nonisolated func worktreeAdminEntries(for repoRoot: URL) async throws -> [WorktreeAdminEntry] {
    let commonDir = try await gitCommonDirectory(for: repoRoot)
    let worktreesDir = commonDir.appending(path: "worktrees", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    var isDir: ObjCBool = false
    let exists = fileManager.fileExists(
      atPath: worktreesDir.path(percentEncoded: false),
      isDirectory: &isDir
    )
    guard exists, isDir.boolValue else { return [] }
    let contents =
      (try? fileManager.contentsOfDirectory(
        at: worktreesDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    return contents.compactMap(Self.readAdminEntry(at:))
  }

  // Read `<worktree>/.git` (the linked-worktree pointer file) and
  // resolve the admin directory it points at. The `gitdir:` line may
  // be absolute or relative to the worktree dir (git 2.48+ with
  // `worktree.useRelativePaths`); resolve against `worktreeURL` so
  // relative pointers don't get mistaken for orphans.
  nonisolated static func adminDirectory(forWorktreeAt worktreeURL: URL) -> URL? {
    let worktreeBase = worktreeURL.standardizedFileURL
    let gitPointer = worktreeBase.appending(path: ".git")
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: gitPointer.path(percentEncoded: false),
      isDirectory: &isDir
    )
    guard exists, !isDir.boolValue else { return nil }
    guard let raw = try? String(contentsOf: gitPointer, encoding: .utf8) else {
      return nil
    }
    let prefix = "gitdir:"
    for rawLine in raw.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix(prefix) else { continue }
      let pathPart = String(line.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !pathPart.isEmpty else { return nil }
      return URL(fileURLWithPath: pathPart, relativeTo: worktreeBase).standardizedFileURL
    }
    return nil
  }

  /// A linked worktree whose `.git` pointer file is missing: git can't use it and
  /// resolves its path up to the repo root (#616). Only the missing-file case
  /// counts (git's own prune criterion), so a transiently unreadable `.git` is
  /// never treated as broken.
  nonisolated static func isGitdirLinkBroken(worktreeDirectory: URL) -> Bool {
    let gitPointer = worktreeDirectory.appending(path: ".git")
    return !FileManager.default.fileExists(atPath: gitPointer.path(percentEncoded: false))
  }

  /// Outcome of `removeSupacodeLock`, so callers can log precisely rather than
  /// assume a release happened.
  nonisolated enum SupacodeLockRemoval {
    case removed
    case keptForeignLock
    case notPresent
    case failed(Error)
  }

  nonisolated static func writeSupacodeLock(at adminDirectory: URL) {
    let lockFile = adminDirectory.appending(path: "locked")
    try? currentSupacodeLockPayload().write(to: lockFile, atomically: true, encoding: .utf8)
  }

  @discardableResult
  nonisolated static func removeSupacodeLock(at adminDirectory: URL) -> SupacodeLockRemoval {
    let lockFile = adminDirectory.appending(path: "locked")
    let path = lockFile.path(percentEncoded: false)
    guard FileManager.default.fileExists(atPath: path) else { return .notPresent }
    // Don't strip a user's `git worktree lock --reason "..."`; only remove the
    // file when it parses as a Supacode-owned payload.
    guard let raw = try? String(contentsOf: lockFile, encoding: .utf8),
      parseSupacodeLockMetadata(from: raw) != nil
    else { return .keptForeignLock }
    do {
      try FileManager.default.removeItem(at: lockFile)
      return .removed
    } catch {
      return .failed(error)
    }
  }

  // Stamp version/build for forensics on stranded lock files.
  nonisolated static func currentSupacodeLockPayload() -> String {
    let info = Bundle.main.infoDictionary
    let metadata = SupacodeWorktreeLockMetadata(
      owner: supacodeLockOwner,
      version: info?["CFBundleShortVersionString"] as? String,
      build: info?["CFBundleVersion"] as? String,
      createdAt: Int64(Date().timeIntervalSince1970)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(metadata),
      let payload = String(bytes: data, encoding: .utf8)
    else {
      return Self.minimalSupacodeLockPayload
    }
    return payload
  }

  nonisolated private static let minimalSupacodeLockPayload = #"{"owner":"supacode"}"#

  nonisolated static func parseSupacodeLockMetadata(
    from reason: String
  ) -> SupacodeWorktreeLockMetadata? {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    guard let metadata = try? JSONDecoder().decode(SupacodeWorktreeLockMetadata.self, from: data)
    else {
      return nil
    }
    return metadata.owner == supacodeLockOwner ? metadata : nil
  }

  nonisolated private static func readAdminEntry(at adminDirectory: URL) -> WorktreeAdminEntry? {
    let adminBase = adminDirectory.standardizedFileURL
    let gitdirFile = adminBase.appending(path: "gitdir")
    guard let raw = try? String(contentsOf: gitdirFile, encoding: .utf8) else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // gitdir content may be absolute or relative to the admin dir.
    let gitPointerURL = URL(fileURLWithPath: trimmed, relativeTo: adminBase)
    let worktreeDirectory = gitPointerURL.deletingLastPathComponent().standardizedFileURL
    let lockFile = adminBase.appending(path: "locked")
    let lockReason: String?
    if FileManager.default.fileExists(atPath: lockFile.path(percentEncoded: false)) {
      let contents = (try? String(contentsOf: lockFile, encoding: .utf8)) ?? ""
      lockReason = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      lockReason = nil
    }
    return WorktreeAdminEntry(
      adminDirectory: adminBase,
      worktreeDirectory: worktreeDirectory,
      lockReason: lockReason
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

  // Failures (collision, invalid ref, missing source) surface as
  // `GitClientError.commandFailed` so the caller can map stderr.
  nonisolated func renameBranch(
    from oldName: String,
    to newName: String,
    for repoRoot: URL
  ) async throws {
    let path = repoRoot.path(percentEncoded: false)
    _ = try await runGit(
      operation: .branchRename,
      arguments: ["-C", path, "branch", "-m", oldName, newName]
    )
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
    try await referenceQueries.isBareRepository(for: repoRoot)
  }

  nonisolated func branchRefs(for repoRoot: URL) async throws -> [String] {
    try await referenceQueries.branchRefs(for: repoRoot)
  }

  nonisolated func branchInventory(for repoRoot: URL, remoteNames: [String]) async throws -> GitBranchInventory {
    try await referenceQueries.branchInventory(for: repoRoot, remoteNames: remoteNames)
  }

  nonisolated func defaultRemoteBranchRef(for repoRoot: URL) async throws -> String? {
    try await referenceQueries.defaultRemoteBranchRef(for: repoRoot)
  }

  /// Returns the list of configured remote names for a repository.
  nonisolated func remoteNames(for repoRoot: URL) async throws -> [String] {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .remoteList,
      arguments: ["-C", path, "remote"]
    )
    return
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Fetches updates from the given remote.
  nonisolated func fetchRemote(_ remote: String, for repoRoot: URL) async throws {
    let path = repoRoot.path(percentEncoded: false)
    _ = try await runGit(
      operation: .fetchOrigin,
      arguments: ["-C", path, "fetch", remote]
    )
  }

  nonisolated func automaticWorktreeBaseRef(for repoRoot: URL) async -> String? {
    await referenceQueries.automaticWorktreeBaseRef(for: repoRoot)
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
          copyFiles: copyFiles,
          baseRef: baseRef,
          directoryOverride: nil
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
    baseRef: String,
    directoryOverride: URL? = nil
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    AsyncThrowingStream { continuation in
      // Let `git worktree add` run to completion even if the consumer drops the
      // stream: killing it mid-operation can leave a half-created worktree and a
      // dangling admin entry, and it finishes quickly on its own.
      Task {
        let repositoryRootURL = repoRoot.standardizedFileURL
        do {
          let wtURL = try wtScriptURL()
          let arguments = createWorktreeArguments(
            baseDirectory: baseDirectory,
            name: name,
            copyFiles: copyFiles,
            baseRef: baseRef,
            directoryOverride: directoryOverride
          )
          let localeArguments = ["LANG=C", "LC_ALL=C", "LC_MESSAGES=C"]
          let baseCommand =
            ["/usr/bin/env"] + localeArguments
            + [wtURL.path(percentEncoded: false)] + arguments
          let command = baseCommand.joined(separator: " ")
          // `git worktree add` checks out the working tree, which runs the LFS
          // smudge filter; augment PATH so `git` can find `git-lfs` (#663).
          let invocation = Self.pathAugmentedInvocation(command: baseCommand)
          var pathLine: String?
          do {
            for try await streamEvent in shell.runLoginStream(
              invocation.executable,
              invocation.arguments,
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
                let resourceValues = try? worktreeURL.resourceValues(forKeys: [
                  .creationDateKey, .contentModificationDateKey,
                ])
                let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
                let worktree = Worktree(
                  location: .local(workingDirectory: worktreeURL, repositoryRoot: repositoryRootURL),
                  kind: .git,
                  name: name,
                  detail: detail,
                  createdAt: createdAt
                )
                if let adminDir = Self.adminDirectory(forWorktreeAt: worktreeURL) {
                  Self.writeSupacodeLock(at: adminDir)
                }
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

  /// Stream a `git clone` into `destination`, yielding progress lines then the
  /// resolved directory. Env vars fail fast on credential / host-key prompts (no
  /// tty to answer). A cancelled or failed clone removes a directory it created.
  nonisolated func cloneStream(
    repositoryURL: String,
    into destination: URL,
    branch: String?,
    depth: Int?
  ) -> AsyncThrowingStream<GitCloneEvent, Error> {
    AsyncThrowingStream { continuation in
      let destinationURL = destination.standardizedFileURL
      // Only a dir the clone created (absent or empty before) is ours to remove on
      // failure; a pre-existing file, symlink, or non-empty dir is the user's.
      let destinationHadContent = Self.destinationHasContent(at: destinationURL)
      let arguments = Self.cloneArguments(
        repositoryURL: repositoryURL, destination: destinationURL, branch: branch, depth: depth)
      // `GIT_TERMINAL_PROMPT=0` suppresses git's own HTTPS prompt; the ssh command
      // fails fast on a passphrase / host-key prompt and a stalled connect instead
      // of hanging the modal with no tty to answer.
      let environmentArguments = [
        "LANG=C", "LC_ALL=C", "LC_MESSAGES=C",
        "GIT_TERMINAL_PROMPT=0",
        "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new",
        "git",
      ]
      let baseCommand = ["/usr/bin/env"] + environmentArguments + arguments
      // Redact the url userinfo (token / password) from everything shown to the
      // user. Match the credential substring, not the whole url, so it survives
      // git's url normalization in echoed auth-failure messages.
      let credentials = Self.cloneCredentials(of: repositoryURL)
      let command = Self.redacting(
        baseCommand.joined(separator: " "),
        credentials: credentials
      )
      // Cloning an LFS repo checks out the working tree, which runs the LFS
      // smudge filter; augment PATH so `git` can find `git-lfs` (#663).
      let invocation = Self.pathAugmentedInvocation(command: baseCommand)
      // `log: false` keeps the clone command (and any embedded token) out of the
      // shell debug log.
      let process = shell.runLoginProcess(invocation.executable, invocation.arguments, nil, log: false)
      let cancelRequested = LockIsolated(false)
      // Drain to completion even after the consumer cancels so partial-clone
      // cleanup runs after git exits rather than racing its teardown.
      Task.detached {
        do {
          for try await event in process.events {
            switch event {
            case .line(let line):
              let redacted = ShellStreamLine(
                source: line.source, text: Self.redacting(line.text, credentials: credentials))
              continuation.yield(.outputLine(redacted))
            case .finished:
              // A cancel that races this success leaves a complete clone on disk
              // (harmless: a valid repo, just not added) rather than a partial one.
              continuation.yield(.finished(directory: destinationURL))
              continuation.finish()
              return
            }
          }
          // Events ended without `.finished`: the process exited from a
          // terminate() (cancel) or genuinely empty output. Drop a dir we created.
          Self.removePartialClone(at: destinationURL, ifCreated: !destinationHadContent)
          if cancelRequested.value {
            continuation.finish(throwing: CancellationError())
          } else {
            continuation.finish(throwing: GitClientError.commandFailed(command: command, message: "Empty output"))
          }
        } catch {
          Self.removePartialClone(at: destinationURL, ifCreated: !destinationHadContent)
          if cancelRequested.value {
            continuation.finish(throwing: CancellationError())
          } else if let gitError = error as? GitClientError {
            continuation.finish(throwing: gitError)
          } else {
            // Redact the url userinfo from git's stdout/stderr before the footer.
            let redactedError = Self.redacting(error, credentials: credentials)
            continuation.finish(throwing: wrapShellError(redactedError, operation: .clone, command: command))
          }
        }
      }
      continuation.onTermination = { reason in
        guard case .cancelled = reason else { return }
        cancelRequested.setValue(true)
        // Kill git; the drain finishes after it exits, then cleans up.
        process.terminate()
      }
    }
  }

  /// Well-known fixed directories where `git-lfs` and similar PATH-based git
  /// filter helpers install, appended to PATH so a non-interactive login shell
  /// that misses them can still run the LFS smudge filter (#663). The per-user
  /// `~/.local/bin` is added separately so it resolves on the execution host.
  nonisolated static func gitFilterHelperDirectories() -> [String] {
    [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/opt/local/bin",
    ]
  }

  /// Wraps `command` so `directories` and the execution host's `~/.local/bin`
  /// are appended to the caller login shell's PATH, then execs it in place:
  /// appending keeps an rc-resolvable helper's precedence, and `exec` keeps a
  /// single pid so termination still targets `git`.
  nonisolated static func pathAugmentedInvocation(
    command: [String],
    directories: [String] = gitFilterHelperDirectories()
  ) -> (executable: URL, arguments: [String]) {
    // The fixed dirs are single-quoted literals; `$HOME/.local/bin` is left for
    // the executing shell to expand so a remote host uses its own HOME (and it
    // is dropped when HOME is unset). `${PATH:+$PATH:}` avoids a leading colon
    // that would otherwise put the cwd on PATH.
    let fixed = SSHCommand.shellQuote(directories.joined(separator: ":"))
    let script = "export PATH=\"${PATH:+$PATH:}\"\(fixed)\"${HOME:+:$HOME/.local/bin}\"; exec \"$@\""
    return (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh"] + command)
  }

  /// `git clone` argv. The url and destination travel as positional arguments
  /// after `--` so a url beginning with `-` is never read as a flag.
  nonisolated static func cloneArguments(
    repositoryURL: String,
    destination: URL,
    branch: String?,
    depth: Int?
  ) -> [String] {
    var arguments = ["clone", "--progress"]
    if let branch, !branch.isEmpty {
      arguments.append("--branch")
      arguments.append(branch)
    }
    if let depth, depth > 0 {
      arguments.append("--depth")
      arguments.append(String(depth))
    }
    arguments.append("--")
    arguments.append(repositoryURL)
    arguments.append(destination.path(percentEncoded: false))
    return arguments
  }

  /// Whether `destination` holds content the clone did not create (a pre-existing
  /// file, symlink, or non-empty dir), so a failed clone must not remove it. An
  /// absent path or an empty dir returns false: that is the clone's to clean up.
  nonisolated static func destinationHasContent(at destination: URL) -> Bool {
    let path = destination.path(percentEncoded: false)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
    guard isDirectory.boolValue else { return true }
    return (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty != true
  }

  /// Remove a clone directory Supacode created, logging a cleanup failure. Never
  /// touches a directory that existed before the clone.
  nonisolated static func removePartialClone(at destination: URL, ifCreated created: Bool) {
    guard created, FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
      return
    }
    do {
      try FileManager.default.removeItem(at: destination)
    } catch {
      gitLogger.warning(
        "clone cleanup failed at \(destination.path(percentEncoded: false)): \(error.localizedDescription)")
    }
  }

  /// Git's "humanish" directory name for a clone url (last path component, `.git`
  /// stripped). Parses the raw string so scp-style remotes (`git@host:org/repo.git`)
  /// work where Foundation's `URL` does not. Empty string when no leaf derives.
  nonisolated static func humanishName(forCloneURL url: String) -> String {
    var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if let queryIndex = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) {
      trimmed = String(trimmed[..<queryIndex])
    }
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    if let separatorIndex = trimmed.lastIndex(where: { $0 == "/" || $0 == ":" }) {
      trimmed = String(trimmed[trimmed.index(after: separatorIndex)...])
    }
    if trimmed.hasSuffix(".git") {
      trimmed.removeLast(4)
    }
    return trimmed
  }

  /// The secret userinfo of a clone url (`token` or `user:password`) in its raw
  /// in-url form so it matches what git echoes. An http(s) bare user is a token; an
  /// ssh user (`git@host`) is just a login name, not a secret, so it is excluded.
  /// nil when there is no credential to redact.
  nonisolated static func cloneCredentials(of url: String) -> String? {
    guard let components = URLComponents(string: url),
      let user = components.percentEncodedUser, !user.isEmpty
    else {
      return nil
    }
    // An explicit password is a secret on any scheme; a bare user is one only on
    // http(s). Redacting an ssh login name would mangle `git` and the host in
    // surfaced output.
    if let password = components.percentEncodedPassword, !password.isEmpty {
      return "\(user):\(password)"
    }
    guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return nil
    }
    return user
  }

  /// Replace `credentials` with `***` in `text`, a no-op when `credentials` is
  /// nil. Matches the bare credential substring so it survives git's url
  /// normalization (trailing slash, dropped `.git`, percent-encoding).
  nonisolated static func redacting(_ text: String, credentials: String?) -> String {
    guard let credentials else { return text }
    return text.replacing(credentials, with: "***")
  }

  /// Redact `credentials` from a shell error's captured output, leaving
  /// non-`ShellClientError` errors (and a nil credential) untouched.
  nonisolated static func redacting(_ error: Error, credentials: String?) -> Error {
    guard let credentials, let shellError = error as? ShellClientError else { return error }
    return ShellClientError(
      command: shellError.command.replacing(credentials, with: "***"),
      stdout: shellError.stdout.replacing(credentials, with: "***"),
      stderr: shellError.stderr.replacing(credentials, with: "***"),
      exitCode: shellError.exitCode
    )
  }

  nonisolated private func createWorktreeArguments(
    baseDirectory: URL,
    name: String,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String,
    directoryOverride: URL?
  ) -> [String] {
    var arguments = ["--base-dir", baseDirectory.path(percentEncoded: false), "sw"]
    if copyFiles.ignored {
      arguments.append("--copy-ignored")
    }
    if copyFiles.untracked {
      arguments.append("--copy-untracked")
    }
    if !baseRef.isEmpty {
      arguments.append("--from")
      arguments.append(baseRef)
    }
    if let directoryOverride {
      arguments.append("--path")
      arguments.append(directoryOverride.path(percentEncoded: false))
    }
    if copyFiles.ignored || copyFiles.untracked {
      arguments.append("--verbose")
    }
    arguments.append(name)
    return arguments
  }

  /// Resolve the current branch via `git rev-parse --abbrev-ref HEAD` so it
  /// works over any transport (local or SSH). Returns the short branch name,
  /// `"HEAD"` for a detached head, or `nil` on error (not a repo / unreachable
  /// host). Replaces the former local-HEAD-file read, which couldn't resolve a
  /// remote worktree's branch.
  nonisolated func symbolicHeadBranch(at worktreeURL: URL) async -> String? {
    let path = worktreeURL.path(percentEncoded: false)
    guard
      let output = try? await runGit(
        operation: .symbolicHeadRef,
        arguments: ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
      )
    else {
      return nil
    }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
    // `worktreePath` feeds the git command, which runs over `shell` (ssh for a
    // remote worktree), so it's the display path for either kind.
    let worktreePath = worktree.workingDirectory.standardizedFileURL.path(percentEncoded: false)
    // The lock release / relocate / trash steps are *local* filesystem work, so
    // they run only when a local URL exists. A remote worktree's
    // `localWorkingDirectory` is nil, so a coincidental local path at the same
    // absolute path can never be touched: `git worktree remove --force --force`
    // on the host is the removal there.
    let relocatedURL: URL?
    if let localWorktreeURL = worktree.localWorkingDirectory?.standardizedFileURL {
      await releaseSupacodeLock(forWorktreeAt: localWorktreeURL, repoRoot: worktree.repositoryRootURL)
      relocatedURL = Self.relocateWorktreeDirectory(localWorktreeURL)
    } else {
      relocatedURL = nil
    }
    // Prune is silent on still-locked entries; the --force --force
    // remove below is the actual guarantee.
    _ = try? await runGit(
      operation: .worktreePrune,
      arguments: ["-C", rootPath, "worktree", "prune", "--expire=now"]
    )
    do {
      try await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
    } catch {
      // A local worktree's directory was already relocated to the trash above,
      // so failing the git bookkeeping is non-fatal. A remote worktree has no
      // such fallback: the host remove is the only deletion, so surface the
      // failure unless git reports the entry was already gone.
      if worktree.localWorkingDirectory == nil, !Self.isWorktreeAlreadyRemoved(error) {
        throw error
      }
    }
    if deleteBranch, !worktree.name.isEmpty {
      // Don't leak the relocated trash dir below if the branch lookup throws.
      let names = (try? await localBranchNames(for: worktree.repositoryRootURL)) ?? []
      if names.contains(worktree.name.lowercased()) {
        _ = try? await runGit(
          operation: .branchDelete,
          arguments: ["-C", rootPath, "branch", "-D", worktree.name]
        )
      }
    }
    if let relocatedURL {
      Task.detached {
        try? FileManager.default.removeItem(at: relocatedURL)
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

  nonisolated static func preferredBaseRef(remote: String?, localHead: String?) -> String? {
    GitReferenceQueries.preferredBaseRef(remote: remote, localHead: localHead)
  }

  /// Probe whether the `git` binary itself is blocked at the environment level
  /// (e.g. an unaccepted Xcode license). Returns `nil` when git runs normally or
  /// fails for a repository-specific reason.
  nonisolated func gitEnvironmentError() async -> GitEnvironmentError? {
    do {
      _ = try await runGit(operation: .version, arguments: ["--version"], localePinned: true)
      return nil
    } catch {
      // `git --version` failing at all means git is unusable. Classify the known
      // gates; otherwise fall back to the command-line-tools remedy (covers a
      // missing binary / exit 127) and log so a reworded gate stays diagnosable.
      if let classified = GitEnvironmentError(classifying: error) {
        return classified
      }
      gitLogger.warning(
        "git --version failed without a known gate signature: \(error.localizedDescription)")
      return .developerToolsUnavailable
    }
  }

  nonisolated private func runGit(
    operation: GitOperation,
    arguments: [String],
    localePinned: Bool = false
  ) async throws -> String {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    // Pin the C locale for the environment probe so its diagnostics stay English
    // and classify regardless of the user's system language.
    let invocation = (localePinned ? ["LC_ALL=C", "LANG=C"] : []) + ["git"] + arguments
    let command = ([env.path(percentEncoded: false)] + invocation).joined(separator: " ")
    do {
      return try await shell.run(env, invocation, nil).stdout
    } catch {
      throw wrapShellError(error, operation: operation, command: command)
    }
  }

  nonisolated private func runWtList(repoRoot: URL) async throws -> String {
    let wtURL = try wtScriptURL()
    let arguments = ["ls", "--json"]
    return try await runBundledWtProcess(
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

  nonisolated private func runBundledWtProcess(
    operation: GitOperation,
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?
  ) async throws -> String {
    let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
    do {
      return try await shell.run(executableURL, arguments, currentDirectoryURL).stdout
    } catch {
      guard shouldFallbackToLoginShell(error) else {
        throw wrapShellError(error, operation: operation, command: command)
      }
      gitLogger.info("Falling back to login shell for \(operation.rawValue)")
      do {
        return try await shell.runLogin(executableURL, arguments, currentDirectoryURL).stdout
      } catch {
        throw wrapShellError(error, operation: operation, command: command)
      }
    }
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

  /// Stat the filesystem first so a directory URL built without a trailing-slash
  /// flag (a freshly cloned destination, where `hasDirectoryPath` is false)
  /// resolves to itself, not its parent (which runs `wt` outside the repo).
  nonisolated static func directoryURL(for path: URL) -> URL {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path.path(percentEncoded: false), isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return path
    }
    if path.hasDirectoryPath {
      return path
    }
    return path.deletingLastPathComponent()
  }

  nonisolated private func runGitWorktreeRemove(
    rootPath: String,
    worktreePath: String
  ) async throws {
    // Double `--force` overrides both "dirty worktree" and "locked
    // worktree" so an orphan whose lock survived an unlock attempt
    // still gets cleaned up.
    _ = try await runGit(
      operation: .worktreeRemove,
      arguments: [
        "-C",
        rootPath,
        "worktree",
        "remove",
        "--force",
        "--force",
        worktreePath,
      ]
    )
  }

  /// True when `git worktree remove` failed only because the entry was already
  /// gone, so a remote removal with no local fallback can treat it as success.
  nonisolated private static func isWorktreeAlreadyRemoved(_ error: Error) -> Bool {
    guard let gitError = error as? GitClientError,
      case .commandFailed(_, let message) = gitError
    else {
      return false
    }
    let lowered = message.lowercased()
    return lowered.contains("is not a working tree")
      || lowered.contains("no such file or directory")
  }

  // Scan-fallback handles orphan rows whose `<worktree>/.git` pointer file
  // is unreadable; path comparison is symlink-resolved to match git's form.
  nonisolated private func releaseSupacodeLock(
    forWorktreeAt worktreeURL: URL,
    repoRoot: URL
  ) async {
    if let adminDir = Self.adminDirectory(forWorktreeAt: worktreeURL) {
      Self.removeSupacodeLock(at: adminDir)
      return
    }
    guard let entries = try? await worktreeAdminEntries(for: repoRoot) else { return }
    let target = Self.canonicalPath(of: worktreeURL)
    guard
      let match = entries.first(where: {
        Self.canonicalPath(of: $0.worktreeDirectory) == target
      })
    else { return }
    Self.removeSupacodeLock(at: match.adminDirectory)
  }

  // `resolvingSymlinksInPath` skips the leaf when it's missing on disk;
  // resolve the parent and re-append so orphan paths still normalize.
  nonisolated private static func canonicalPath(of url: URL) -> String {
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent()
    let resolvedParent = parent.resolvingSymlinksInPath()
    let leaf = standardized.lastPathComponent
    if leaf.isEmpty { return resolvedParent.path(percentEncoded: false) }
    return resolvedParent.appending(path: leaf).path(percentEncoded: false)
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

nonisolated private func shouldFallbackToLoginShell(_ error: Error) -> Bool {
  guard let shellError = error as? ShellClientError else {
    return false
  }
  if shellError.exitCode == 127 {
    return true
  }
  let output = "\(shellError.stderr)\n\(shellError.stdout)".lowercased()
  return output.contains("command not found")
}

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
