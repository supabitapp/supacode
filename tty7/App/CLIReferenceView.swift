import SwiftUI

struct CLIReferenceView: View {
  var body: some View {
    Form {
      // swiftlint:disable line_length
      Section {
        Text(
          "The \(code("tty7")) command is available in all tty7 terminal sessions. Run \(code("tty7 --help")) for built-in usage information."
        )
        .foregroundStyle(.secondary)
        Text(
          "Inside a tty7 terminal, flags default to the current session's IDs. Outside, pass explicit IDs from \(code("tty7 worktree list")) or \(code("tty7 repo list"))."
        )
        .foregroundStyle(.secondary)
        Text(
          "Commands that create resources (\(code("tab new")), \(code("surface split"))) print the new UUID to stdout. Capture it to target the resource afterward."
        )
        .foregroundStyle(.secondary)
        // swiftlint:enable line_length
      } header: {
        Text("CLI Reference").font(.title.bold())
        Text("Control tty7 from the terminal.")
      }

      CLISection(title: "App", rows: Self.appRows)
      CLISection(title: "Worktree", rows: Self.worktreeRows)
      CLISection(title: "Tab", rows: Self.tabRows)
      CLISection(title: "Surface", rows: Self.surfaceRows)
      CLISection(title: "Repository", rows: Self.repoRows)
      CLISection(title: "Settings", rows: Self.settingsRows)
      CLISection(title: "Socket", rows: Self.socketRows)

      Section("Flags") {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
          ForEach(Self.flagRows) { row in
            GridRow {
              Text(row.command)
                .font(.body.monospaced())
                .gridColumnAlignment(.leading)
              Text(row.description)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            }
          }
        }
      }
    }
    .textSelection(.enabled)
    .formStyle(.grouped)
    .frame(minWidth: 300)
    .navigationTitle("")
  }

  // MARK: - Row data.

  private static let appRows: [CLIEntry] = [
    .init(command: "tty7", description: "Bring tty7 to front."),
    .init(command: "tty7 open", description: "Same as above."),
  ]

  private static let worktreeRows: [CLIEntry] = [
    .init(command: "tty7 worktree list [-f]", description: "List worktree IDs. -f for focused only."),
    .init(command: "tty7 worktree focus [-w <id>]", description: "Focus a worktree."),
    .init(
      command: "tty7 worktree run [-w <id>] [-c <uuid>]",
      description: "Run a script. Defaults to the primary run-kind script; -c targets a specific one."
    ),
    .init(
      command: "tty7 worktree stop [-w <id>] [-c <uuid>]",
      description: "Stop a script. Defaults to all run-kind scripts; -c targets a specific one."
    ),
    .init(
      command: "tty7 worktree script list [-w <id>]",
      description: "List configured scripts. Underlined rows are currently running."
    ),
    .init(command: "tty7 worktree archive [-w <id>]", description: "Archive the worktree."),
    .init(command: "tty7 worktree unarchive [-w <id>]", description: "Unarchive the worktree."),
    .init(command: "tty7 worktree delete [-w <id>]", description: "Delete the worktree."),
    .init(command: "tty7 worktree pin [-w <id>]", description: "Pin the worktree."),
    .init(command: "tty7 worktree unpin [-w <id>]", description: "Unpin the worktree."),
  ]

  private static let tabRows: [CLIEntry] = [
    .init(command: "tty7 tab list [-w <id>] [-f]", description: "List tab UUIDs. -f for focused only."),
    .init(command: "tty7 tab focus [-w <id>] [-t <id>]", description: "Focus a tab."),
    .init(
      command: "tty7 tab new [-w <id>] [-i <cmd>] [-n <uuid>]",
      description: "Create a new tab. Prints UUID to stdout."
    ),
    .init(command: "tty7 tab close [-w <id>] [-t <id>]", description: "Close a tab."),
  ]

  private static let surfaceRows: [CLIEntry] = [
    .init(
      command: "tty7 surface list [-w <id>] [-t <id>] [-f]",
      description: "List surface UUIDs. -f for focused only."
    ),
    .init(
      command: "tty7 surface focus [-w <id>] [-t <id>] [-s <id>] [-i <cmd>]",
      description: "Focus a surface."
    ),
    .init(
      command: "tty7 surface split [-w <id>] [-t <id>] [-s <id>] [-d h|v] [-i <cmd>] [-n <uuid>]",
      description: "Split a surface. Prints UUID to stdout."
    ),
    .init(
      command: "tty7 surface close [-w <id>] [-t <id>] [-s <id>]",
      description: "Close a surface."
    ),
  ]

  private static let repoRows: [CLIEntry] = [
    .init(command: "tty7 repo list", description: "List repository IDs."),
    .init(command: "tty7 repo open <path>", description: "Open a repository."),
    .init(
      command:
        "tty7 repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--fetch] "
        + "[--name <folder>] [--location <dir>]",
      description: "Create a worktree in a repository."
    ),
  ]

  private static let settingsRows: [CLIEntry] = [
    .init(command: "tty7 settings", description: "Open settings."),
    .init(command: "tty7 settings <section>", description: "Open a specific section."),
    .init(command: "tty7 settings repo [-r <id>]", description: "Open repository settings."),
  ]

  private static let socketRows: [CLIEntry] = [
    .init(command: "tty7 socket", description: "List active socket paths.")
  ]

  private static let flagRows: [CLIEntry] = [
    .init(command: "-w, --worktree", description: "Worktree ID. Defaults to $TTY7_WORKTREE_ID."),
    .init(command: "-t, --tab", description: "Tab UUID. Defaults to $TTY7_TAB_ID."),
    .init(command: "-s, --surface", description: "Surface UUID. Defaults to $TTY7_SURFACE_ID."),
    .init(command: "-c, --script", description: "Script UUID (for `worktree run`/`stop`)."),
    .init(command: "-r, --repo", description: "Repository ID. Defaults to $TTY7_REPO_ID."),
    .init(command: "-i, --input", description: "Command to run in the terminal."),
    .init(command: "-d, --direction", description: "Split direction: horizontal (h) or vertical (v)."),
    .init(command: "-n, --id", description: "UUID for a new tab or surface."),
    .init(command: "-f, --focused", description: "Print only the focused item in list commands."),
  ]
}

// MARK: - Components.

private struct CLIEntry: Identifiable {
  let id = UUID()
  let command: String
  let description: String
}

private struct CLISection: View {
  let title: String
  let rows: [CLIEntry]

  var body: some View {
    Section(title) {
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
        ForEach(rows) { row in
          GridRow {
            Text(row.command)
              .font(.body.monospaced())
              .gridColumnAlignment(.leading)
            Text(row.description)
              .foregroundStyle(.secondary)
              .gridColumnAlignment(.leading)
          }
        }
      }
    }
  }
}

/// Inline code fragment styled as monospaced primary foreground.
private func code(_ value: String) -> Text {
  Text(value).monospaced().foregroundStyle(.primary)
}
