import ArgumentParser
import Foundation

/// `supacode worktree script` — inspect user-defined scripts for a worktree.
/// Lives at the top level (not nested in `WorktreeCommand`) so SwiftLint's
/// `nesting` rule stays satisfied while still appearing as a `worktree`
/// subcommand at runtime via its `commandName`.
struct WorktreeScriptCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "script",
    abstract: "Inspect user-defined scripts for a worktree.",
    subcommands: [List.self],
    defaultSubcommand: List.self
  )
}

extension WorktreeScriptCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List scripts configured for a worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      let items = try QueryDispatcher.query(resource: "scripts", params: ["worktreeID": id])
      for item in items {
        let running = !(item["running"] ?? "").isEmpty
        print(formatScriptListLine(item, running: running))
      }
    }
  }
}
