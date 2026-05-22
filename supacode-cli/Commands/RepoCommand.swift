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

    func run() throws {
      let items = try QueryDispatcher.query(resource: "repos")
      for item in items {
        print(item["id"] ?? "")
      }
    }
  }

  struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open a repository.")

    @Argument(help: "Absolute path to the repository.")
    var path: String

    func run() throws {
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.repoOpen(path: path))
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

    @Flag(help: "Fetch origin before creating the worktree.")
    var fetch = false

    @Option(help: "Folder name for the worktree. Defaults to the branch name.")
    var name: String?

    @Option(help: "Parent directory the worktree folder is created in.")
    var location: String?

    func run() throws {
      let rID = try resolveRepoID(repo)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.repoWorktreeNew(
          repoID: rID,
          options: .init(branch: branch, base: base, fetch: fetch, name: name, location: location)
        )
      )
    }
  }
}
