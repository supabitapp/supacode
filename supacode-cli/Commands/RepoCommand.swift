import ArgumentParser
import Foundation

struct RepoCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "repo",
    abstract: "Manage repositories.",
    subcommands: [
      List.self,
      Open.self,
      WorktreeNew.self,
    ]
  )
}

// MARK: - Subcommands.

extension RepoCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List repositories.")

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let items = try QueryDispatcher.query(resource: "repos", timeoutSeconds: timeoutOption.timeout)
      for item in items {
        print(item["id"] ?? "")
      }
    }
  }

  struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Open a repository, or adopt an existing worktree.",
      discussion: """
        Prints the id of whatever the path resolved to: a repository, or the \
        worktree it named. A path inside a worktree resolves to that worktree. \
        A path that resolves to nothing exits non-zero with an explanation \
        rather than reporting success without opening anything.
        """
    )

    @Argument(help: "Absolute path to a repository, a worktree, or a directory inside either.")
    var path: String

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      // Prints the adopted repository or worktree id. A path that adopts nothing
      // now reports an error from the app and exits non-zero.
      let id = try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.repoOpen(path: path),
        timeoutSeconds: timeoutOption.timeout
      )
      if let id { print(id) }
    }
  }

  struct WorktreeNew: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "worktree-new",
      abstract: "Create a new worktree in a repository."
    )

    @Option(name: [.short, .long], help: "Repository ID. Defaults to $SUPACODE_REPO_ID.")
    var repo: String?

    @Option(help: "Branch name for the new worktree.")
    var branch: String?

    @Option(help: "Base ref for the new worktree.")
    var base: String?

    @Option(help: "Upstream branch the new branch tracks. Defaults to Git's automatic tracking.")
    var upstream: String?

    @Flag(help: "Create the new branch with no upstream, overriding Git's automatic tracking.")
    var noUpstream = false

    @Flag(help: "Fetch origin before creating the worktree.")
    var fetch = false

    @Flag(
      name: .customLong("reuse-existing-branch"),
      help: """
        Check out --branch if it already exists instead of creating it. Without \
        this flag an existing branch name is refused. A branch already checked \
        out in another worktree is refused either way.
        """
    )
    var reuseExistingBranch = false

    @Option(help: "Folder name for the worktree. Defaults to the branch name.")
    var name: String?

    @Option(help: "Parent directory the worktree folder is created in.")
    var location: String?

    @Flag(help: "Pin the worktree as soon as creation starts (local repositories).")
    var pin = false

    @OptionGroup var backgroundOption: BackgroundOption

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      if upstream != nil, noUpstream {
        throw ValidationError("--upstream and --no-upstream are mutually exclusive.")
      }
      // Keep the empty-value wire encoding of "no upstream" out of the CLI surface.
      if let upstream, upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ValidationError("--upstream requires a branch name; use --no-upstream to clear tracking.")
      }
      // Without --branch the name is generated from unused names, so there is
      // never an existing branch to reuse.
      if reuseExistingBranch, branch == nil {
        throw ValidationError("--reuse-existing-branch requires --branch.")
      }
    }

    func run() throws {
      let rID = try IDResolvers.resolveRepoID(repo)
      // An empty `upstream` query value means "no upstream"; omitted means automatic.
      let resolvedUpstream = noUpstream ? "" : upstream
      let id = try Dispatcher.dispatch(
        deeplinkURL: backgroundOption.applied(
          to: DeeplinkURLBuilder.repoWorktreeNew(
            repoID: rID,
            options: .init(
              branch: branch, base: base, upstream: resolvedUpstream, fetch: fetch, name: name,
              location: location, pin: pin, reuseExistingBranch: reuseExistingBranch)
          )),
        timeoutSeconds: timeoutOption.timeout
      )
      if let id { print(id) }
    }
  }
}
