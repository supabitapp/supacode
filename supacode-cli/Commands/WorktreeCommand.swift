import ArgumentParser
import Foundation

struct WorktreeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "Manage worktrees.",
    subcommands: [
      List.self,
      Status.self,
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

    struct OutputRow: Equatable {
      let id: String
      let status: String?
      let focused: Bool

      var line: String {
        guard let status else { return id }
        return "\(id)\t\(status)"
      }
    }

    @Flag(name: [.short, .long], help: "Print only the focused worktree.")
    var focused = false

    @Option(
      name: .long,
      help: "Print only worktrees matching these comma-separated statuses: \(WorktreeStatus.allValues)."
    )
    var status: String?

    @Flag(name: .long, help: "Print only worktrees that are not archived.")
    var notArchived = false

    @Flag(name: .long, help: "Append a tab-separated status column to each row.")
    var withStatus = false

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard status == nil || !notArchived else {
        throw ValidationError("Pass either --status or --not-archived, not both.")
      }
      _ = try Self.requestedStatuses(status)
    }

    func run() throws {
      let items = try QueryDispatcher.query(resource: "worktrees", timeoutSeconds: timeoutOption.timeout)
      for row in try Self.outputRows(
        items: items,
        focusedOnly: focused,
        statuses: Self.requestedStatuses(status),
        notArchivedOnly: notArchived,
        withStatus: withStatus
      ) {
        print(ListFormatting.line(row.line, focused: row.focused))
      }
    }

    static let staleAppMessage =
      "The running Supacode app does not report worktree status. Restart Supacode to pick up the update."

    static func requestedStatuses(_ value: String?) throws -> Set<WorktreeStatus> {
      guard let value else { return [] }
      let names = value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !names.isEmpty else {
        throw ValidationError("--status needs at least one of: \(WorktreeStatus.allValues).")
      }
      return try Set(
        names.map { name in
          guard let status = WorktreeStatus(rawValue: name) else {
            throw ValidationError("Unknown status '\(name)'. Expected one of: \(WorktreeStatus.allValues).")
          }
          return status
        }
      )
    }

    static func outputRows(
      items: [[String: String]],
      focusedOnly: Bool,
      statuses: Set<WorktreeStatus>,
      notArchivedOnly: Bool,
      withStatus: Bool
    ) throws -> [OutputRow] {
      let needsStatus = withStatus || notArchivedOnly || !statuses.isEmpty
      // An app build predating `worktree status` omits the field. Fail loudly
      // rather than silently filter to nothing or print a blank column.
      if needsStatus, items.contains(where: { $0[Key.status] == nil }) {
        throw SocketClient.Error.responseError(Self.staleAppMessage)
      }
      var rows: [OutputRow] = []
      rows.reserveCapacity(items.count)
      for item in items {
        let isFocused = !(item[Key.focused] ?? "").isEmpty
        guard !focusedOnly || isFocused else { continue }
        let raw = item[Key.status] ?? ""
        let status = WorktreeStatus(rawValue: raw)
        guard statuses.isEmpty || status.map(statuses.contains) == true else { continue }
        guard !notArchivedOnly || status?.isArchived != true else { continue }
        rows.append(
          OutputRow(
            id: ListFormatting.sanitizeColumn(item[Key.id] ?? ""),
            // Pass an unrecognized value through so a newer app's status is not
            // reported as blank by an older bundled binary.
            status: withStatus ? ListFormatting.sanitizeColumn(raw) : nil,
            focused: isFocused
          )
        )
      }
      return rows
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Read a worktree's sidebar status, archived flag, and focus.")

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let id = try resolveWorktreeID(worktree)
      let items: [[String: String]]
      do {
        items = try QueryDispatcher.query(
          resource: "worktreeStatus",
          params: ["worktreeID": id],
          timeoutSeconds: timeoutOption.timeout
        )
      } catch let error as SocketClient.Error {
        // An app build predating this resource rejects it by name.
        guard case .responseError(let message) = error, message.contains("Unknown resource") else {
          throw error
        }
        throw SocketClient.Error.responseError(List.staleAppMessage)
      }
      guard let item = items.first, let status = item[Key.status] else {
        throw SocketClient.Error.responseError("Worktree status query returned no rows.")
      }
      print("\(Key.status)=\(ListFormatting.sanitizeColumn(status))")
      print("\(Key.archived)=\(ListFormatting.sanitizeColumn(item[Key.archived] ?? ""))")
      print("\(Key.focused)=\(ListFormatting.sanitizeColumn(item[Key.focused] ?? ""))")
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
        "\(Key.title)=\(ListFormatting.sanitizeColumn(item[Key.title] ?? ""))",
        "\(Key.color)=\(ListFormatting.sanitizeColumn(item[Key.color] ?? "none"))",
      ]
      if let displayTitle = item[Key.displayTitle] {
        lines.append("\(Key.displayTitle)=\(ListFormatting.sanitizeColumn(displayTitle))")
      }
      return lines
    }
  }
}

// MARK: - Wire contract.

extension WorktreeCommand {
  /// Mirrors `SidebarState.WorktreeStatus` (app side); keep in sync.
  nonisolated enum WorktreeStatus: String, CaseIterable {
    case main
    case pinned
    case unpinned
    case archived

    static let allValues = WorktreeStatus.allCases.map(\.rawValue).joined(separator: "|")

    var isArchived: Bool { self == .archived }
  }

  /// Socket wire keys. Mirrors `WorktreeStatusQueryResponse.Key` (app side);
  /// keep in sync (the CLI links no shared module to stay dependency-light).
  fileprivate nonisolated enum Key {
    static let id = "id"
    static let focused = "focused"
    static let status = "status"
    static let archived = "archived"
  }
}
