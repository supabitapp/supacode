import ArgumentParser
import Foundation

struct WorktreeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Manage worktrees.",
    subcommands: [
      List.self,
      Focus.self,
      Run.self,
      Stop.self,
      Archive.self,
      Unarchive.self,
      Delete.self,
      Pin.self,
      Unpin.self,
    ],
    defaultSubcommand: Focus.self
  )
}

// MARK: - Subcommands.

extension WorktreeCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List worktrees.")

    @Flag(name: [.short, .long], help: "Print only the focused worktree.")
    var focused = false

    func run() throws {
      let items = try QueryDispatcher.query(resource: "worktrees")
      for item in items {
        let isFocused = !(item["focused"] ?? "").isEmpty
        guard !focused || isFocused else { continue }
        print(formatListLine(item["id"] ?? "", focused: isFocused))
      }
    }
  }

  struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeSelect(worktreeID: id))
    }
  }

  struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the worktree script.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("run", worktreeID: id))
    }
  }

  struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the running script.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("stop", worktreeID: id))
    }
  }

  struct Archive: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Archive the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("archive", worktreeID: id))
    }
  }

  struct Unarchive: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unarchive the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("unarchive", worktreeID: id))
    }
  }

  struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("delete", worktreeID: id))
    }
  }

  struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pin the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("pin", worktreeID: id))
    }
  }

  struct Unpin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpin the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.worktreeAction("unpin", worktreeID: id))
    }
  }
}
