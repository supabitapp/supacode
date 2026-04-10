import ArgumentParser
import Foundation

struct SurfaceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "surface",
    abstract: "Manage terminal surfaces.",
    subcommands: [
      List.self,
      Focus.self,
      Split.self,
      Close.self,
    ],
    defaultSubcommand: Focus.self
  )
}

// MARK: - Subcommands.

extension SurfaceCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List surfaces in a tab.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    @Flag(name: [.short, .long], help: "Print only the focused surface.")
    var focused = false

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      let items = try QueryDispatcher.query(resource: "surfaces", params: ["worktreeID": wID, "tabID": tID])
      for item in items {
        let isFocused = !(item["focused"] ?? "").isEmpty
        guard !focused || isFocused else { continue }
        print(formatListLine(item["id"] ?? "", focused: isFocused))
      }
    }
  }

  struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a surface.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    @Option(name: [.short, .long], help: "Surface ID. Defaults to $SUPACODE_SURFACE_ID.")
    var surface: String?

    @Option(name: [.short, .long], help: "Command to send to the surface.")
    var input: String?

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      let sID = try resolveSurfaceID(surface)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.surfaceFocus(worktreeID: wID, tabID: tID, surfaceID: sID, input: input)
      )
    }
  }

  struct Split: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Split a surface.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    @Option(name: [.short, .long], help: "Surface ID. Defaults to $SUPACODE_SURFACE_ID.")
    var surface: String?

    @Option(name: [.short, .long], help: "Command to run in the new surface.")
    var input: String?

    @Option(name: [.short, .long], help: "Split direction: horizontal (h) or vertical (v).")
    var direction: CLISplitDirection?

    @Option(name: [.short, .customLong("id")], help: "UUID for the new surface.")
    var newID: String?

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      let sID = try resolveSurfaceID(surface)
      let resolvedID = newID ?? UUID().uuidString
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.surfaceSplit(
          worktreeID: wID,
          tabID: tID,
          surfaceID: sID,
          options: .init(direction: direction?.rawValue, input: input, id: resolvedID)
        )
      )
      print(resolvedID)
    }
  }

  struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a surface.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.short, .long], help: "Tab ID. Defaults to $SUPACODE_TAB_ID.")
    var tab: String?

    @Option(name: [.short, .long], help: "Surface ID. Defaults to $SUPACODE_SURFACE_ID.")
    var surface: String?

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let tID = try resolveTabID(tab)
      let sID = try resolveSurfaceID(surface)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.surfaceClose(worktreeID: wID, tabID: tID, surfaceID: sID)
      )
    }
  }
}
