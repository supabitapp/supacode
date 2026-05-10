import ArgumentParser
import Foundation

struct IntegrationCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "integration",
    abstract: "Internal protocol used by Supacode-installed agent hooks. Not for direct use.",
    subcommands: [Event.self]
  )
}

extension IntegrationCommand {
  /// Sends a JSON hook-event envelope to the running Supacode app.
  /// Silent no-op when Supacode is not running so hook execution never fails
  /// on a missing socket.
  struct Event: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "event",
      abstract: "Send a hook event to the running Supacode app."
    )

    @Argument(help: "Event name, e.g. session_start, session_end, busy_on, busy_off, notification.")
    var name: String

    @Option(help: "Agent that fired the event (claude, codex, kiro, pi, …).")
    var agent: String

    @Option(name: .customLong("surface-id"), help: "Surface UUID. Defaults to $SUPACODE_SURFACE_ID.")
    var surfaceID: String?

    @Option(name: .customLong("tab-id"), help: "Tab UUID. Defaults to $SUPACODE_TAB_ID.")
    var tabID: String?

    @Option(name: .customLong("worktree-id"), help: "Worktree path. Defaults to $SUPACODE_WORKTREE_ID.")
    var worktreeID: String?

    @Option(help: "Agent process pid.")
    var pid: Int?

    @Option(help: "Optional event-specific JSON payload (object).")
    var data: String?

    func run() throws {
      let environment = ProcessInfo.processInfo.environment
      guard let resolvedSurfaceID = surfaceID ?? environment["SUPACODE_SURFACE_ID"] else {
        throw ValidationError("Missing --surface-id (and $SUPACODE_SURFACE_ID is unset).")
      }
      guard let resolvedTabID = tabID ?? environment["SUPACODE_TAB_ID"] else {
        throw ValidationError("Missing --tab-id (and $SUPACODE_TAB_ID is unset).")
      }
      guard let resolvedWorktreeID = worktreeID ?? environment["SUPACODE_WORKTREE_ID"] else {
        throw ValidationError("Missing --worktree-id (and $SUPACODE_WORKTREE_ID is unset).")
      }
      var envelope: [String: Any] = [
        "event": name,
        "v": 1,
        "agent": agent,
        "surface_id": resolvedSurfaceID,
        "tab_id": resolvedTabID,
        "worktree_id": resolvedWorktreeID,
        "ts": Date().ISO8601Format(),
      ]
      if let pid { envelope["pid"] = pid }
      if let data, !data.isEmpty {
        // Validate the data payload is a JSON object before sending — keeps
        // malformed bridge invocations from poisoning the wire.
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
          throw ValidationError("--data must be a JSON object.")
        }
        envelope["data"] = parsed
      }

      guard let socketPath = Self.locateSocket() else { return }
      let payload = try JSONSerialization.data(withJSONObject: envelope)
      // Best-effort send. Hook events must never fail the agent, so we swallow
      // transport errors silently — the app will simply miss this event.
      try? SocketClient.sendAndReceive(to: socketPath, data: payload)
    }

    /// Resolves the socket without launching the app — events are fire-and-forget.
    private static func locateSocket() -> String? {
      if let envPath = SocketDiscovery.fromEnvironment(), SocketDiscovery.isAlive(envPath) {
        return envPath
      }
      let existing = (try? SocketDiscovery.listAll()) ?? []
      return existing.count == 1 ? existing[0] : nil
    }

  }
}
