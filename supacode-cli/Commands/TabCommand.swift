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
      Move.self,
      Close.self,
    ],
    defaultSubcommand: Focus.self
  )
}

// MARK: - Subcommands.

extension TabCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List tabs in a worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Flag(name: [.short, .long], help: "Print only the focused tab.")
    var focused = false

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let items = try QueryDispatcher.query(
        resource: "tabs",
        params: ["worktreeID": wID],
        timeoutSeconds: timeoutOption.timeout
      )
      for item in items {
        let isFocused = !(item["focused"] ?? "").isEmpty
        guard !focused || isFocused else { continue }
        print(ListFormatting.line(item["id"] ?? "", focused: isFocused))
      }
    }
  }

  struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to the focused tab.")
    var tab: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let tID = try IDResolvers.resolveFocusedTabID(tab, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabFocus(worktreeID: wID, tabID: tID),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct New: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Command to run in the new tab.")
    var input: String?

    @Option(name: [.short, .customLong("id")], help: "UUID for the new tab.")
    var newID: String?

    @Option(name: .long, help: "Persistent title for the new tab.")
    var title: String?

    @Option(
      name: [.customShort("p"), .customLong("pane")],
      help: "Pane to add the tab to (a pane, tab, or content UUID). Defaults to the focused pane.")
    var pane: String?

    @OptionGroup var backgroundOption: BackgroundOption

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      if let pane, UUID(uuidString: pane) == nil {
        throw ValidationError("--pane must be a pane, tab, or content UUID.")
      }
      try IDResolvers.validateNewID(newID)
      // A new tab has no override to clear, so a blank title would be dropped silently.
      guard let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      throw ValidationError("--title cannot be blank. Omit it to keep the terminal title.")
    }

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let resolvedID = newID ?? UUID().uuidString
      try Dispatcher.dispatch(
        deeplinkURL: backgroundOption.applied(
          to: DeeplinkURLBuilder.tabNew(
            worktreeID: wID,
            input: input,
            id: resolvedID,
            title: title,
            pane: pane
          )),
        timeoutSeconds: timeoutOption.timeout
      )
      print(resolvedID)
    }
  }

  struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to the focused tab.")
    var tab: String?

    @Option(name: .long, help: "Persistent title for the tab. An empty title clears the override.")
    var title: String

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let tID = try IDResolvers.resolveFocusedTabID(tab, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabRename(worktreeID: wID, tabID: tID, title: title),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move a tab into a new split.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to the focused tab.")
    var tab: String?

    @Option(name: [.short, .long], help: "Direction: left, right, up, or down.")
    var direction: CLIFocusDirection

    @OptionGroup var backgroundOption: BackgroundOption

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let tID = try IDResolvers.resolveFocusedTabID(tab, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: backgroundOption.applied(
          to: DeeplinkURLBuilder.tabMove(worktreeID: wID, tabID: tID, direction: direction.rawValue)),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to the focused tab.")
    var tab: String?

    @OptionGroup var backgroundOption: BackgroundOption

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let tID = try IDResolvers.resolveFocusedTabID(tab, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: backgroundOption.applied(
          to: DeeplinkURLBuilder.tabClose(worktreeID: wID, tabID: tID)),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
