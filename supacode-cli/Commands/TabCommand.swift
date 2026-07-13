import ArgumentParser
import CryptoKit
import Foundation

struct TabCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Manage terminal tabs.",
    subcommands: [
      List.self,
      Focus.self,
      New.self,
      AdoptZmx.self,
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

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let wID = try resolveWorktreeID(worktree)
      let resolvedID = newID ?? UUID().uuidString
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabNew(worktreeID: wID, input: input, id: resolvedID),
        timeoutSeconds: timeoutOption.timeout
      )
      print(resolvedID)
    }
  }

  struct AdoptZmx: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "adopt-zmx",
      abstract: "Add or move an existing zmx session into a worktree tab."
    )

    @Argument(help: "Existing zmx session name.")
    var session: String

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(help: "Tab title to show in Supacode.")
    var title: String?

    @Option(name: [.short, .customLong("id")], help: "Stable UUID for the adopted tab.")
    var newID: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let sessionID = try ZmxSessionArgument.normalized(session)
      let worktreeID = try resolveWorktreeID(worktree)
      let resolvedID: String
      if let newID {
        resolvedID = try Self.validatedTabID(newID)
      } else {
        resolvedID = Self.stableTabID(sessionID: sessionID)
      }
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.tabAdoptZmx(
          worktreeID: worktreeID,
          sessionID: sessionID,
          title: title,
          id: resolvedID
        ),
        timeoutSeconds: timeoutOption.timeout
      )
      print(resolvedID)
    }

    private static func stableTabID(sessionID: String) -> String {
      let digest = SHA256.hash(data: Data("supacode:zmx-session:\(sessionID)".utf8))
      var bytes = Array(digest.prefix(16))
      bytes[6] = (bytes[6] & 0x0f) | 0x50
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      return UUID(
        uuid: (
          bytes[0], bytes[1], bytes[2], bytes[3],
          bytes[4], bytes[5],
          bytes[6], bytes[7],
          bytes[8], bytes[9],
          bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        )
      ).uuidString
    }

    private static func validatedTabID(_ raw: String) throws -> String {
      guard let uuid = UUID(uuidString: raw) else {
        throw ValidationError("Invalid --id value: expected a UUID.")
      }
      return uuid.uuidString
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

private nonisolated enum ZmxSessionArgument {
  static func normalized(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ValidationError("zmx session name cannot be empty.")
    }
    guard trimmed != ".", trimmed != "..",
      !trimmed.unicodeScalars.contains(where: isRejectedScalar)
    else {
      throw ValidationError("zmx session name cannot be '.', '..', contain '/', or contain control characters.")
    }
    return trimmed
  }

  private static func isRejectedScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value == 0 || scalar.value == 0x2F || CharacterSet.controlCharacters.contains(scalar)
  }
}
