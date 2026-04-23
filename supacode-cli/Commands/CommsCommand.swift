import ArgumentParser
import Foundation

struct CommsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comms",
    abstract: "Send and inspect local conversation messages.",
    subcommands: [
      List.self,
      Send.self,
    ],
    defaultSubcommand: List.self
  )
}

extension CommsCommand {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List recent conversation messages for a worktree."
    )

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.customShort("l"), .long], help: "Maximum messages to print.")
    var limit = 20

    func run() throws {
      let worktreeID = try resolveWorktreeID(worktree)
      let items = try QueryDispatcher.query(
        resource: "comms.messages",
        params: [
          "worktreeID": worktreeID,
          "limit": String(limit),
        ]
      )
      for item in items {
        let line = [
          item["createdAt"] ?? "",
          item["sender"] ?? "agent",
          escapeField(item["title"] ?? ""),
          escapeField(item["body"] ?? ""),
        ]
        .joined(separator: "\t")
        print(line)
      }
    }
  }

  struct Send: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Append a message to the local conversation pane."
    )

    @Option(name: [.short, .long], help: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktree: String?

    @Option(name: [.long], help: "Name shown in the conversation pane. Defaults to 'agent'.")
    var sender = "agent"

    @Option(name: [.long], help: "Optional message title.")
    var title: String?

    @Option(name: [.long], help: "Message body.")
    var body: String

    func run() throws {
      let worktreeID = try resolveWorktreeID(worktree)
      let trimmedSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !trimmedBody.isEmpty else {
        throw ValidationError("Message body cannot be empty.")
      }

      try CommandDispatcher.dispatch(
        command: "comms.send",
        params: [
          "worktreeID": worktreeID,
          "sender": trimmedSender.isEmpty ? "agent" : trimmedSender,
          "title": trimmedTitle ?? "",
          "body": trimmedBody,
        ]
      )
    }
  }
}

private func escapeField(_ value: String) -> String {
  value
    .replacing("\\", with: "\\\\")
    .replacing("\t", with: "\\t")
    .replacing("\n", with: "\\n")
}
