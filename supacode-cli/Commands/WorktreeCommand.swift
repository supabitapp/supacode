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
      WorktreeScriptCommand.self,
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

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let items = try QueryDispatcher.query(resource: "worktrees", timeoutSeconds: timeoutOption.timeout)
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

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeSelect(worktreeID: id),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Run a script. Defaults to the primary run-kind script when --script is omitted."
    )

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.customShort("c"), .long], help: "Script UUID (see `worktree script list`).")
    var script: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      guard let script else {
        try Dispatcher.dispatch(
          deeplinkURL: DeeplinkURLBuilder.worktreeAction("run", worktreeID: id),
          timeoutSeconds: timeoutOption.timeout
        )
        return
      }
      let scriptID = try validatedScriptID(script)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.scriptRun(worktreeID: id, scriptID: scriptID),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Stop a running script. Defaults to all run-kind scripts when --script is omitted."
    )

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.customShort("c"), .long], help: "Script UUID (see `worktree script list`).")
    var script: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      guard let script else {
        try Dispatcher.dispatch(
          deeplinkURL: DeeplinkURLBuilder.worktreeAction("stop", worktreeID: id),
          timeoutSeconds: timeoutOption.timeout
        )
        return
      }
      let scriptID = try validatedScriptID(script)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.scriptStop(worktreeID: id, scriptID: scriptID),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Archive: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Archive the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeAction("archive", worktreeID: id),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Unarchive: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unarchive the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeAction("unarchive", worktreeID: id),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeAction("delete", worktreeID: id),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pin the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeAction("pin", worktreeID: id),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Unpin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpin the worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeAction("unpin", worktreeID: id),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
