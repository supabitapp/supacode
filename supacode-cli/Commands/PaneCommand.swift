import ArgumentParser
import Foundation

struct PaneCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "Manage layout panes (split-tree leaves that hold tabs).",
    subcommands: [
      List.self,
      Focus.self,
      Split.self,
      Close.self,
      Zoom.self,
      Equalize.self,
      Window.self,
    ],
    defaultSubcommand: Split.self
  )
}

// MARK: - Subcommands.

extension PaneCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List pane UUIDs in a worktree.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Flag(name: [.short, .long], help: "Print only the focused pane.")
    var focused = false

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let items = try QueryDispatcher.query(
        resource: "panes",
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
    static let configuration = CommandConfiguration(
      abstract: "Focus a pane by id (-p) or its neighbor by direction (-d).")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(
      name: [.customShort("p"), .customLong("pane")],
      help: "Pane to focus (a pane, tab, or content UUID).")
    var pane: String?

    @Option(name: [.short, .long], help: "Neighbor direction: left, right, up, or down.")
    var direction: CLIFocusDirection?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard pane != nil || direction != nil else {
        throw ValidationError("Pass -p <pane-id> to focus a pane, or -d <direction> for a neighbor.")
      }
      guard pane == nil || direction == nil else {
        throw ValidationError("Pass either -p or -d, not both.")
      }
    }

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let url: String
      if let direction {
        url = DeeplinkURLBuilder.paneFocusDirection(worktreeID: wID, direction: direction.rawValue)
      } else {
        url = DeeplinkURLBuilder.paneFocus(worktreeID: wID, paneID: pane ?? "")
      }
      try Dispatcher.dispatch(deeplinkURL: url, timeoutSeconds: timeoutOption.timeout)
    }
  }

  struct Split: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Split a pane into a new pane. Prints the new tab UUID to stdout.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(
      name: [.customShort("p"), .customLong("pane")],
      help: "Pane to split (a pane, tab, or content UUID). Defaults to the focused pane.")
    var pane: String?

    @Option(name: [.short, .long], help: "Command to run in the new pane.")
    var input: String?

    @Option(name: [.short, .long], help: "Split direction: horizontal (h) or vertical (v).")
    var direction: CLISplitDirection?

    @Option(name: [.short, .customLong("id")], help: "UUID for the new tab.")
    var newID: String?

    @OptionGroup var backgroundOption: BackgroundOption

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      try IDResolvers.validateNewID(newID)
    }

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let token = try IDResolvers.resolveFocusedPaneToken(pane, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      let resolvedID = newID ?? UUID().uuidString
      try Dispatcher.dispatch(
        deeplinkURL: backgroundOption.applied(
          to: DeeplinkURLBuilder.paneSplit(
            worktreeID: wID,
            paneToken: token,
            options: .init(direction: direction?.rawValue, input: input, id: resolvedID)
          )),
        timeoutSeconds: timeoutOption.timeout
      )
      print(resolvedID)
    }
  }

  struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a pane and all its tabs.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(
      name: [.customShort("p"), .customLong("pane")],
      help: "Pane to close (a pane, tab, or content UUID). Defaults to the focused pane.")
    var pane: String?

    @OptionGroup var backgroundOption: BackgroundOption

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let token = try IDResolvers.resolveFocusedPaneToken(pane, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: backgroundOption.applied(
          to: DeeplinkURLBuilder.paneClose(worktreeID: wID, paneToken: token)),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Zoom: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle a pane's zoom.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(
      name: [.customShort("p"), .customLong("pane")],
      help: "Pane to zoom (a pane, tab, or content UUID). Defaults to the focused pane.")
    var pane: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let token = try IDResolvers.resolveFocusedPaneToken(pane, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.paneZoom(worktreeID: wID, paneToken: token),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Equalize: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Equalize every split ratio.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.paneEqualize(worktreeID: wID),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }

  struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Toggle a pane's window mode.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to the focused worktree.")
    var worktree: String?

    @Option(
      name: [.customShort("p"), .customLong("pane")],
      help: "Pane to toggle (a pane, tab, or content UUID). Defaults to the focused pane.")
    var pane: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try IDResolvers.resolveFocusedWorktreeID(worktree, timeoutSeconds: timeoutOption.timeout)
      let token = try IDResolvers.resolveFocusedPaneToken(pane, worktreeID: wID, timeoutSeconds: timeoutOption.timeout)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.paneWindow(worktreeID: wID, paneToken: token),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
