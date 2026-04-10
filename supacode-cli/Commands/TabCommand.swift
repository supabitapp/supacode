import ArgumentParser
import Foundation

struct TabCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Manage terminal tabs.",
    subcommands: [
      List.self,
      Focus.self,
      New.self,
      Close.self,
    ],
    defaultSubcommand: Focus.self
  )
}

// MARK: - Subcommands.

extension TabCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List tabs in a worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Flag(name: [.short, .long], help: "Print only the focused tab.")
    var focused = false

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let items = try QueryDispatcher.query(resource: "tabs", params: ["worktreeID": wID])
      for item in items {
        let isFocused = !(item["focused"] ?? "").isEmpty
        guard !focused || isFocused else { continue }
        print(formatListLine(item["id"] ?? "", focused: isFocused))
      }
    }
  }

  struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.tabFocus(worktreeID: wID, tabID: tID))
    }
  }

  struct New: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Command to run in the new tab.")
    var input: String?

    @Option(name: [.short, .customLong("id")], help: "UUID for the new tab.")
    var newID: String?

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let resolvedID = newID ?? UUID().uuidString
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabNew(worktreeID: wID, input: input, id: resolvedID)
      )
      print(resolvedID)
    }
  }

  struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.tabClose(worktreeID: wID, tabID: tID))
    }
  }
}
