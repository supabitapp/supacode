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
      Appearance.self,
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

  struct Appearance: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Read stored sidebar appearance overrides or update them."
    )

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(help: "Sidebar title override. Pass an empty string to clear it.")
    var title: String?

    @Option(help: "Sidebar tint override: red|orange|yellow|green|teal|blue|purple, #RRGGBB[AA], or none to clear.")
    var color: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      guard title != nil || color != nil else {
        let items = try QueryDispatcher.query(
          resource: "worktreeAppearance",
          params: ["worktreeID": id],
          timeoutSeconds: timeoutOption.timeout
        )
        guard let item = items.first else {
          throw SocketClient.Error.responseError("Worktree appearance query returned no rows.")
        }
        for line in Self.formattedAppearance(item) {
          print(line)
        }
        return
      }

      let color = try color.map(CLIWorktreeColor.validated)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.worktreeAppearance(worktreeID: id, title: title, color: color),
        timeoutSeconds: timeoutOption.timeout
      )
    }

    /// Socket wire keys. Mirrors `WorktreeAppearanceQueryResponse.Key` (app side);
    /// keep in sync (the CLI links no shared module to stay dependency-light).
    private enum Key {
      static let title = "title"
      static let color = "color"
      static let displayTitle = "displayTitle"
    }

    private static func formattedAppearance(_ item: [String: String]) -> [String] {
      var lines = [
        "\(Key.title)=\(sanitizeValue(item[Key.title] ?? ""))",
        "\(Key.color)=\(sanitizeValue(item[Key.color] ?? "none"))",
      ]
      if let displayTitle = item[Key.displayTitle] {
        lines.append("\(Key.displayTitle)=\(sanitizeValue(displayTitle))")
      }
      return lines
    }

    private static func sanitizeValue(_ value: String) -> String {
      value.replacing("\t", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
    }
  }
}
