import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared

extension RepositoriesFeature {
  /// Dedicated reducer for the add / edit remote-connection form. Lives apart
  /// from the main `body` switch so the form's `ifLet` child reducer runs
  /// before the delegate handler nils the presented state, and so `body` stays
  /// under the Swift type-checker's complexity limit (mirrors
  /// `worktreeCustomizationReducer`).
  static var remoteConnectionFormReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requestAddRemoteRepository:
        state.remoteConnectionForm = RemoteConnectionFormFeature.State(mode: .add)
        return .none

      case .requestEditRemoteRepository(let repositoryID):
        presentRemoteConnectionEditForm(repositoryID, state: &state)
        return .none

      case .remoteConnectionForm(.presented(.delegate(.cancel))):
        state.remoteConnectionForm = nil
        return .none

      case .remoteConnectionForm(.presented(.delegate(.save(let config)))):
        return saveRemoteConnection(config, state: &state)

      default:
        return .none
      }
    }
  }

  /// Repository.ID for a remote config. Host-keyed and prefixed so it can never
  /// collide with a local repository's id (an absolute filesystem path) nor
  /// with another host pointing at the same remote path. Because this is not a
  /// filesystem path, the local-only `buildRepositorySections` loop (which keys
  /// `repositories[id:]` off `rootURL.path`) never matches a remote repo, so
  /// remote repos are rendered solely by the dedicated remote loop.
  nonisolated static func remoteRepositoryID(for config: RemoteRepositoryConfig) -> Repository.ID {
    RepositoryLocation.remote(config.host, path: config.normalizedRemotePath).id
  }

  /// Host-keyed git worktree id `remote://<user@host:port><remotePath>` so
  /// worktrees at the same path on different hosts (or matching a local path)
  /// never collide.
  nonisolated static func remoteWorktreeID(host: RemoteHost, worktreePath: String) -> Worktree.ID {
    WorktreeID("remote://" + host.authority + worktreePath)
  }

  /// The persisted remote-repository configs. Read through `@Shared` so every
  /// load path (initial, reload, open, removal) sees the same source of truth.
  static func persistedRemoteRepositoryConfigs() -> [RemoteRepositoryConfig] {
    @Shared(.settingsFile) var settingsFile
    return settingsFile.global.remoteRepositories
  }

  /// An empty placeholder for a remote repository, rendered immediately while
  /// the real listing resolves asynchronously over SSH (and when the host is
  /// unreachable). Carries the host so selection / terminal attach still work.
  nonisolated static func remotePlaceholderRepository(
    config: RemoteRepositoryConfig,
    repoID: Repository.ID
  ) -> Repository {
    Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      worktrees: [],
      isGitRepository: true,
      host: config.host
    )
  }

  /// Wall-clock bound for resolving one remote config. The ssh probe profile
  /// fails fast for an unreachable host, but a reachable host whose command
  /// stalls (a stale ControlMaster, a wedged remote shell) would otherwise hang;
  /// this hard timeout flips such a row to "can't reach".
  static let remoteLoadTimeout: Duration = .seconds(10)

  /// Loads one remote config over SSH, bounded by `remoteLoadTimeout`. On a
  /// failure or timeout it returns a placeholder repository (kept so the entry
  /// is never pruned) paired with a `LoadFailure`, so the sidebar renders a
  /// "can't reach" row like a missing local folder. The timeout cancels the
  /// in-flight ssh (which terminates the process), so a stalled host can't keep
  /// the row spinning forever.
  nonisolated static func loadRemoteRepository(
    _ config: RemoteRepositoryConfig,
    repoID: Repository.ID,
    shell: ShellClient? = nil
  ) async -> (repository: Repository, failure: LoadFailure?) {
    enum Outcome: Sendable {
      case resolved(Repository, LoadFailure?)
      case timedOut
    }
    let outcome = await withTaskGroup(of: Outcome.self) { group in
      group.addTask {
        let loaded = await resolveRemoteRepository(config, repoID: repoID, shell: shell)
        return .resolved(loaded.repository, loaded.failure)
      }
      group.addTask {
        try? await Task.sleep(for: remoteLoadTimeout)
        return .timedOut
      }
      let first = await group.next() ?? .timedOut
      group.cancelAll()
      return first
    }
    switch outcome {
    case .resolved(let repository, let failure):
      return (repository, failure)
    case .timedOut:
      repositoriesLogger.warning("loadRemoteRepository: timed out reaching \(config.host.sshDestination)")
      let failure = LoadFailure(
        rootID: repoID,
        message:
          "Can't reach \(config.host.sshDestination). The repository will reappear when the host is reachable."
      )
      return (remotePlaceholderRepository(config: config, repoID: repoID), failure)
    }
  }

  /// The actual SSH resolution behind `loadRemoteRepository`'s timeout. Runs the
  /// non-interactive background-probe profile (`BatchMode` + `ConnectTimeout` +
  /// `ServerAlive*`); any failure becomes a placeholder + `LoadFailure`.
  nonisolated private static func resolveRemoteRepository(
    _ config: RemoteRepositoryConfig,
    repoID: Repository.ID,
    shell: ShellClient? = nil
  ) async -> (repository: Repository, failure: LoadFailure?) {
    let host = config.host
    let rootURL = URL(fileURLWithPath: config.normalizedRemotePath)
    let shell = shell ?? .ssh(host: host, extraOptions: SSHCommand.backgroundProbeOptions)
    let client = GitClient(shell: shell)

    // A populated worktree listing is the unambiguous git case; skip the extra
    // probe round trip for it (the common case).
    var listingThrew = false
    do {
      let loaded = try await client.gitWorktrees(for: rootURL)
      if !loaded.isEmpty {
        let repository = Repository(
          id: repoID,
          rootURL: rootURL,
          name: config.resolvedDisplayName,
          worktrees: IdentifiedArray(uniqueElements: loaded.map { remoteWorktree(from: $0, host: host) }),
          isGitRepository: true,
          host: host
        )
        return (repository, nil)
      }
    } catch {
      listingThrew = true
      repositoriesLogger.warning(
        "remote git worktree listing failed for \(host):\(rootURL.path(percentEncoded: false)): "
          + error.localizedDescription
      )
    }

    // Empty or failed listing: classify so a plain directory renders as a folder
    // and an unreachable host renders as a placeholder rather than a fake repo.
    switch await classifyRemotePath(config.normalizedRemotePath, shell: shell) {
    case .folder:
      return (remoteFolderRepository(config: config, repoID: repoID), nil)
    case .git where listingThrew:
      // It's a git repo, but the worktree listing threw: collapsing to a single
      // synthetic main would silently hide the repo's other worktrees. Surface a
      // failure and keep the placeholder so the next reload re-lists in full.
      let failure = LoadFailure(
        rootID: repoID,
        message:
          "Connected to \(host.sshDestination) but couldn't list worktrees for "
          + "\(config.normalizedRemotePath). Supacode will retry."
      )
      return (remotePlaceholderRepository(config: config, repoID: repoID), failure)
    case .git:
      // Listing succeeded but was empty: a single synthetic main is the best
      // representation of a git repo with nothing else to show.
      let repository = Repository(
        id: repoID,
        rootURL: rootURL,
        name: config.resolvedDisplayName,
        worktrees: IdentifiedArray(uniqueElements: [remoteMainWorktree(config: config)]),
        isGitRepository: true,
        host: host
      )
      return (repository, nil)
    case .missing:
      // Host answered, but the configured path is gone: report the path (not a
      // misleading "can't reach the host") and keep the placeholder.
      let failure = LoadFailure(
        rootID: repoID,
        message:
          "\(config.normalizedRemotePath) was not found on \(host.sshDestination). "
          + "The repository will reappear when the path exists."
      )
      return (remotePlaceholderRepository(config: config, repoID: repoID), failure)
    case .unknown:
      // Unreachable host / ambiguous probe: keep an empty placeholder (so the
      // config isn't pruned and removal / edit still resolve it) and record a
      // load failure so the sidebar shows a "can't reach" row.
      let failure = LoadFailure(
        rootID: repoID,
        message:
          "Can't reach \(host.sshDestination). The repository will reappear when the host is reachable."
      )
      return (remotePlaceholderRepository(config: config, repoID: repoID), failure)
    }
  }

  /// How long the add / edit form waits for the ssh reachability probe before
  /// giving up. Generous enough for a first connect plus interactive auth (a
  /// hardware-key touch), tight enough that an unreachable host fails the form
  /// instead of spinning indefinitely.
  static let remoteResolveTimeout: Duration = .seconds(15)

  /// The last non-empty line of `output`. A login shell sources dotfiles before
  /// running the probe, so any banner they print precedes the command output;
  /// the real result is the final line.
  nonisolated static func lastNonEmptyLine(of output: String) -> String {
    output
      .split(whereSeparator: \.isNewline)
      .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
  }

  /// Resolve a typed remote path to an absolute, canonical path on the host,
  /// expanding a leading `~`. Returns nil when the host is unreachable, the
  /// probe times out, or the path does not exist, so the caller can reject the
  /// add. The path travels as a positional argument (not interpolated into the
  /// script), so spaces and shell metacharacters are safe; only the intended
  /// leading `~` expands.
  static func resolveRemotePath(
    _ path: String,
    host: RemoteHost,
    shell: ShellClient? = nil,
    timeout: Duration = remoteResolveTimeout
  ) async -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let shell = shell ?? .ssh(host: host)
    let script = """
      case "$1" in
        "~") target=$HOME ;;
        "~/"*) target=$HOME/${1#"~/"} ;;
        *) target=$1 ;;
      esac
      cd -- "$target" 2>/dev/null && pwd -P
      """

    enum Outcome {
      case resolved(String)
      case failed
      case timedOut
    }
    return await withTaskGroup(of: Outcome.self) { group in
      group.addTask {
        do {
          let output = try await shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", trimmed], nil)
          let resolved = lastNonEmptyLine(of: output.stdout)
          return resolved.isEmpty ? .failed : .resolved(resolved)
        } catch {
          // Unreachable host vs failed `cd` is indistinguishable here; log so
          // the form's failure has a breadcrumb.
          repositoriesLogger.warning(
            "resolveRemotePath: shell failed for \(host.sshDestination): \(error)"
          )
          return .failed
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return .timedOut
      }
      defer { group.cancelAll() }
      guard let first = await group.next() else { return nil }
      switch first {
      case .resolved(let resolved):
        return resolved
      case .failed:
        return nil
      case .timedOut:
        repositoriesLogger.warning(
          "resolveRemotePath: timed out reaching \(host.sshDestination) after \(timeout)"
        )
        return nil
      }
    }
  }

  /// Whether a remote path is a git work tree, a plain directory, reachable but
  /// absent, or indeterminate. `.missing` (host answered, path gone) is kept
  /// distinct from `.unknown` (host unreachable / probe ambiguous) so the caller
  /// can report an accurate failure instead of a blanket "can't reach".
  enum RemotePathKind: Equatable, Sendable {
    case git
    case folder
    case missing
    case unknown
  }

  /// Classify a remote path over ssh in a single round trip so a non-git
  /// directory can render as a folder. `.missing` when the host answers but the
  /// path is gone; `.unknown` when the host is unreachable or the probe is
  /// ambiguous, so the caller can keep the git fallback rather than mislabel a
  /// transient failure.
  nonisolated static func classifyRemotePath(
    _ remotePath: String,
    shell: ShellClient
  ) async -> RemotePathKind {
    let quoted = "'" + remotePath.replacing("'", with: "'\\''") + "'"
    let script =
      "if [ ! -d \(quoted) ]; then echo supacode-nodir; "
      + "elif git -C \(quoted) rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo supacode-git; "
      + "else echo supacode-folder; fi"
    guard let output = try? await shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], nil) else {
      return .unknown
    }
    let trimmedStdout = lastNonEmptyLine(of: output.stdout)
    switch trimmedStdout {
    case "supacode-git": return .git
    case "supacode-folder": return .folder
    case "supacode-nodir": return .missing
    default:
      repositoriesLogger.warning("classifyRemotePath: unexpected probe stdout: " + trimmedStdout)
      return .unknown
    }
  }

  /// Folder counterpart to a git remote repository: a single synthetic worktree
  /// at the root carrying the host so the terminal still attaches over ssh.
  /// `isGitRepository: false` routes it to the sidebar's folder row. The worktree
  /// id is host-keyed (the same `remoteWorktreeID` scheme as remote git
  /// worktrees), so a remote `~` never collides with a local `~` folder.
  nonisolated static func remoteFolderRepository(
    config: RemoteRepositoryConfig,
    repoID: Repository.ID
  ) -> Repository {
    let folder = Worktree(
      location: .remote(
        config.host, workingDirectory: config.normalizedRemotePath, repositoryRoot: config.normalizedRemotePath),
      kind: .folder,
      name: config.resolvedDisplayName,
      detail: config.host.sshDestination,
      isAttached: false
    )
    return Repository(
      location: .remote(config.host, path: config.normalizedRemotePath),
      kind: .folder,
      name: config.resolvedDisplayName,
      worktrees: IdentifiedArray(uniqueElements: [folder])
    )
  }

  /// Re-key a worktree parsed from the remote `git worktree list` with the host
  /// and a host-keyed id, preserving everything else.
  nonisolated static func remoteWorktree(from base: Worktree, host: RemoteHost) -> Worktree {
    Worktree(
      id: remoteWorktreeID(host: host, worktreePath: base.workingDirectory.path(percentEncoded: false)),
      name: base.name,
      detail: base.detail,
      workingDirectory: base.workingDirectory,
      repositoryRootURL: base.repositoryRootURL,
      createdAt: base.createdAt,
      isMissing: base.isMissing,
      isAttached: base.isAttached,
      host: host
    )
  }

  /// Synthetic main worktree used when the remote git listing is unavailable.
  /// `workingDirectory == repositoryRootURL` so it classifies as the git main.
  nonisolated static func remoteMainWorktree(config: RemoteRepositoryConfig) -> Worktree {
    let rootURL = URL(fileURLWithPath: config.normalizedRemotePath)
    return Worktree(
      id: remoteWorktreeID(host: config.host, worktreePath: config.normalizedRemotePath),
      name: config.resolvedDisplayName,
      detail: config.host.sshDestination,
      workingDirectory: rootURL,
      repositoryRootURL: rootURL,
      isAttached: false,
      host: config.host
    )
  }

  /// Remote worktree creation: pick a name (excluding remote branches), run
  /// `git worktree add` over ssh, then reload to re-list. Bypasses the local
  /// pending/stream flow but honors the prompt's name + base-ref choices. The
  /// base ref is resolved the same way as local (`baseRefSource` → explicit /
  /// repo setting, falling back to the remote's automatic base ref), and the
  /// new worktree lands beside the repo root (`<parent>/<name>`), so no parent
  /// dir needs to be created first.
  func remoteCreateWorktree(
    repository: Repository,
    nameSource: WorktreeCreationNameSource,
    baseRefSource: WorktreeCreationBaseRefSource,
    fetchOrigin: Bool,
    placement: WorktreePlacementOverride?
  ) -> Effect<Action> {
    guard let host = repository.host else { return .none }
    let repoRoot = repository.rootURL
    @Shared(.repositorySettings(repoRoot, host: host)) var remoteRepositorySettings
    let selectedBaseRef = remoteRepositorySettings.worktreeBaseRef
    let existingNames = Set(repository.worktrees.map { $0.name.lowercased() })
    return .run { send in
      let client = GitClient(shell: .ssh(host: host))
      let remoteBranches = (try? await client.localBranchNames(for: repoRoot)) ?? []
      let existing = existingNames.union(remoteBranches)
      let name: String
      switch nameSource {
      case .random:
        let generated = await MainActor.run { WorktreeNameGenerator.nextName(excluding: existing) }
        guard let generated else {
          await send(
            .presentAlert(
              title: "No available worktree names",
              message: "All default adjective-animal names are already in use. "
                + "Delete a worktree or rename a branch, then try again."
            )
          )
          return
        }
        name = generated
      case .explicit(let explicit):
        let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
          await send(
            .presentAlert(
              title: "Branch name invalid",
              message: "Enter a branch name without spaces to create a worktree."
            )
          )
          return
        }
        name = trimmed
      }
      // Parent directory precedence: the prompt's explicit override, then the
      // remote host's Supacode settings (per-repo, then global), then the
      // local-style default (alongside the repo root on the host). The leaf is
      // the prompt's worktree-name override, falling back to the branch name.
      let parentDirectory = await Self.remoteWorktreeParentDirectory(
        host: host, repoRoot: repoRoot, placementPath: placement?.path)
      let leaf = Self.remoteWorktreeLeaf(nameOverride: placement?.name, branchName: name)
      let worktreePath = parentDirectory.appending(path: leaf, directoryHint: .isDirectory)
      let baseRef = await Self.resolveRemoteBaseRef(
        baseRefSource: baseRefSource, selectedBaseRef: selectedBaseRef, client: client, repoRoot: repoRoot)
      await Self.fetchRemoteForBaseRefIfNeeded(
        fetchOrigin: fetchOrigin, baseRef: baseRef, client: client, repoRoot: repoRoot)
      do {
        try await client.createGitWorktree(in: repoRoot, name: name, baseRef: baseRef, worktreePath: worktreePath)
        await send(.loadPersistedRepositories)
      } catch {
        await send(.presentAlert(title: "Unable to create worktree", message: error.localizedDescription))
      }
    }
  }

  /// Leaf folder name for a remote worktree: the prompt's worktree-name override
  /// when it's a valid single path component, otherwise the branch name.
  nonisolated static func remoteWorktreeLeaf(nameOverride: String?, branchName: String) -> String {
    let trimmed = (nameOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, WorktreePlacementOverride.nameValidationError(trimmed) == nil else {
      return branchName
    }
    return trimmed
  }

  /// Parent directory for a new remote worktree. Precedence: the prompt's
  /// explicit parent override, then the remote host's Supacode per-repo
  /// `worktreeBaseDirectoryPath`, then the remote global default (joined with the
  /// repo's directory name), then the local-style default of placing the
  /// worktree alongside the repo root on the host.
  static func remoteWorktreeParentDirectory(
    host: RemoteHost,
    repoRoot: URL,
    placementPath: String?,
    shell: ShellClient? = nil
  ) async -> URL {
    if let placementPath {
      let trimmed = placementPath.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return URL(filePath: trimmed, directoryHint: .isDirectory)
      }
    }
    let bases = await readRemoteWorktreeBaseDirectories(host: host, repoRoot: repoRoot, shell: shell)
    if let perRepo = bases.perRepo?.trimmingCharacters(in: .whitespacesAndNewlines), !perRepo.isEmpty {
      return URL(filePath: perRepo, directoryHint: .isDirectory)
    }
    if let global = bases.global?.trimmingCharacters(in: .whitespacesAndNewlines), !global.isEmpty {
      return URL(filePath: global, directoryHint: .isDirectory)
        .appending(path: repoRoot.lastPathComponent, directoryHint: .isDirectory)
    }
    return repoRoot.deletingLastPathComponent()
  }

  /// Read the remote host's worktree base directories over ssh: the per-repo
  /// value from `<repoRoot>/supacode.json` and the global default from
  /// `~/.supacode/settings.json`. Returns `(nil, nil)` when the host is
  /// unreachable or neither file is present.
  static func readRemoteWorktreeBaseDirectories(
    host: RemoteHost,
    repoRoot: URL,
    shell: ShellClient? = nil
  ) async -> (perRepo: String?, global: String?) {
    let shell = shell ?? .ssh(host: host)
    let repoSettingsPath = repoRoot.appending(path: "supacode.json").path(percentEncoded: false)
    let quotedRepoSettings = "'" + repoSettingsPath.replacing("'", with: "'\\''") + "'"
    // `|| true` keeps a missing file a clean empty section rather than a non-zero exit.
    let script =
      "echo '===SUPACODE-REPO==='; cat \(quotedRepoSettings) 2>/dev/null || true; "
      + #"echo '===SUPACODE-GLOBAL==='; cat "$HOME/.supacode/settings.json" 2>/dev/null || true"#
    guard
      let output = try? await shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], nil)
    else {
      return (nil, nil)
    }
    return parseRemoteWorktreeBaseDirectories(output.stdout)
  }

  /// Pure split + decode of `readRemoteWorktreeBaseDirectories`'s output: the
  /// per-repo `RepositorySettings` block and the global `SettingsFile` block,
  /// separated by the marker lines.
  nonisolated static func parseRemoteWorktreeBaseDirectories(
    _ output: String
  ) -> (perRepo: String?, global: String?) {
    guard
      let repoMarker = output.range(of: "===SUPACODE-REPO==="),
      let globalMarker = output.range(of: "===SUPACODE-GLOBAL===")
    else {
      return (nil, nil)
    }
    let repoJSON = String(output[repoMarker.upperBound..<globalMarker.lowerBound])
    let globalJSON = String(output[globalMarker.upperBound...])
    let perRepo = decode(RepositorySettings.self, from: repoJSON)?.worktreeBaseDirectoryPath
    let global = decode(SettingsFile.self, from: globalJSON)?.global.defaultWorktreeBaseDirectoryPath
    return (perRepo, global)
  }

  nonisolated private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
    let data = Data(json.utf8)
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  /// Resolve the base ref for a remote worktree the same way the local path does
  /// (`baseRefSource` → explicit / repo setting, falling back to the remote's
  /// automatic base ref), defaulting to `HEAD` when nothing resolves so
  /// `git worktree add` always has a concrete committish.
  static func resolveRemoteBaseRef(
    baseRefSource: WorktreeCreationBaseRefSource,
    selectedBaseRef: String?,
    client: GitClient,
    repoRoot: URL
  ) async -> String {
    let resolved: String
    switch baseRefSource {
    case .repositorySetting:
      if let selectedBaseRef, !selectedBaseRef.isEmpty {
        resolved = selectedBaseRef
      } else {
        resolved = await client.automaticWorktreeBaseRef(for: repoRoot) ?? ""
      }
    case .explicit(let explicit):
      if let explicit, !explicit.isEmpty {
        resolved = explicit
      } else {
        resolved = await client.automaticWorktreeBaseRef(for: repoRoot) ?? ""
      }
    }
    return resolved.isEmpty ? "HEAD" : resolved
  }

  /// Mirror the local `fetchOriginBeforeWorktreeCreation` behavior over ssh: when
  /// enabled, list the remote's remotes, match the one the base ref points at
  /// (`<remote>/…`), and `git fetch` it on the host before `git worktree add` so
  /// the new worktree branches from up-to-date refs. Best-effort and non-fatal:
  /// a fetch failure (offline remote, auth) is logged and creation proceeds, same
  /// as local. A base ref with no remote prefix (e.g. a local branch or `HEAD`)
  /// matches nothing and skips the fetch.
  static func fetchRemoteForBaseRefIfNeeded(
    fetchOrigin: Bool,
    baseRef: String,
    client: GitClient,
    repoRoot: URL
  ) async {
    guard fetchOrigin else { return }
    let remotes = (try? await client.remoteNames(for: repoRoot)) ?? []
    guard let matchedRemote = GitReferenceQueries.remotePrefixMatch(ref: baseRef, remoteNames: remotes)?.remote
    else {
      return
    }
    do {
      try await client.fetchRemote(matchedRemote, for: repoRoot)
    } catch {
      repositoriesLogger.warning(
        "remote git fetch \(matchedRemote) failed for \(repoRoot.path(percentEncoded: false)): "
          + error.localizedDescription
      )
    }
  }
}
