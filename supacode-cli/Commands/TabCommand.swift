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
      Rename.self,
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

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let items = try QueryDispatcher.query(
        resource: "tabs",
        params: ["worktreeID": wID],
        timeoutSeconds: timeoutOption.timeout
      )
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

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabFocus(worktreeID: wID, tabID: tID),
        timeoutSeconds: timeoutOption.timeout
      )
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

    @Option(name: .long, help: "Persistent title for the new tab.")
    var title: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      // A new tab has no override to clear, so a blank title would be dropped silently.
      guard let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      throw ValidationError("--title cannot be blank. Omit it to keep the terminal title.")
    }

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let resolvedID = newID ?? UUID().uuidString
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabNew(
          worktreeID: wID,
          input: input,
          id: resolvedID,
          title: title
        ),
        timeoutSeconds: timeoutOption.timeout
      )
      print(resolvedID)
    }
  }

  struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    @Option(name: .long, help: "Persistent title for the tab. An empty title clears the override.")
    var title: String

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabRename(worktreeID: wID, tabID: tID, title: title),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabClose(worktreeID: wID, tabID: tID),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
