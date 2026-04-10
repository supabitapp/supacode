import SwiftUI

struct CLIReferenceView: View {
  var body: some View {
    Form {
      // swiftlint:disable line_length
      Section {
        Text(
          "The \(code("supacode")) command is available in all Supacode terminal sessions. Run \(code("supacode --help")) for built-in usage information."
        )
        .foregroundStyle(.secondary)
        Text(
          "Inside a Supacode terminal, flags default to the current session's IDs. Outside, pass explicit IDs from \(code("supacode worktree list")) or \(code("supacode repo list"))."
        )
        .foregroundStyle(.secondary)
        Text(
          "Commands that create resources (\(code("tab new")), \(code("surface split"))) print the new UUID to stdout. Capture it to target the resource afterward."
        )
        .foregroundStyle(.secondary)
        // swiftlint:enable line_length
      } header: {
        Text("CLI Reference").font(.title.bold())
        Text("Control Supacode from the terminal.")
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
    .init(command: "supacode", description: "Bring Supacode to front."),
    .init(command: "supacode open", description: "Same as above."),
  ]

  private static let worktreeRows: [CLIEntry] = [
    .init(command: "supacode worktree list [-f]", description: "List worktree IDs. -f for focused only."),
    .init(command: "supacode worktree focus [-w <id>]", description: "Focus a worktree."),
    .init(command: "supacode worktree run [-w <id>]", description: "Run the worktree script."),
    .init(command: "supacode worktree stop [-w <id>]", description: "Stop the running script."),
    .init(command: "supacode worktree archive [-w <id>]", description: "Archive the worktree."),
    .init(command: "supacode worktree unarchive [-w <id>]", description: "Unarchive the worktree."),
    .init(command: "supacode worktree delete [-w <id>]", description: "Delete the worktree."),
    .init(command: "supacode worktree pin [-w <id>]", description: "Pin the worktree."),
    .init(command: "supacode worktree unpin [-w <id>]", description: "Unpin the worktree."),
  ]

  private static let tabRows: [CLIEntry] = [
    .init(command: "supacode tab list [-w <id>] [-f]", description: "List tab UUIDs. -f for focused only."),
    .init(command: "supacode tab focus [-w <id>] [-t <id>]", description: "Focus a tab."),
    .init(
      command: "supacode tab new [-w <id>] [-i <cmd>] [-n <uuid>]",
      description: "Create a new tab. Prints UUID to stdout."
    ),
    .init(command: "supacode tab close [-w <id>] [-t <id>]", description: "Close a tab."),
  ]

  private static let surfaceRows: [CLIEntry] = [
    .init(
      command: "supacode surface list [-w <id>] [-t <id>] [-f]",
      description: "List surface UUIDs. -f for focused only."
    ),
    .init(
      command: "supacode surface focus [-w <id>] [-t <id>] [-s <id>] [-i <cmd>]",
      description: "Focus a surface."
    ),
    .init(
      command: "supacode surface split [-w <id>] [-t <id>] [-s <id>] [-d h|v] [-i <cmd>] [-n <uuid>]",
      description: "Split a surface. Prints UUID to stdout."
    ),
    .init(
      command: "supacode surface close [-w <id>] [-t <id>] [-s <id>]",
      description: "Close a surface."
    ),
  ]

  private static let repoRows: [CLIEntry] = [
    .init(command: "supacode repo list", description: "List repository IDs."),
    .init(command: "supacode repo open <path>", description: "Open a repository."),
    .init(
      command: "supacode repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--fetch]",
      description: "Create a worktree in a repository."
    ),
  ]

  private static let settingsRows: [CLIEntry] = [
    .init(command: "supacode settings", description: "Open settings."),
    .init(command: "supacode settings <section>", description: "Open a specific section."),
    .init(command: "supacode settings repo [-r <id>]", description: "Open repository settings."),
  ]

  private static let socketRows: [CLIEntry] = [
    .init(command: "supacode socket", description: "List active socket paths.")
  ]

  private static let flagRows: [CLIEntry] = [
    .init(command: "-w, --worktree", description: "Worktree ID. Defaults to $SUPACODE_WORKTREE_ID."),
    .init(command: "-t, --tab", description: "Tab UUID. Defaults to $SUPACODE_TAB_ID."),
    .init(command: "-s, --surface", description: "Surface UUID. Defaults to $SUPACODE_SURFACE_ID."),
    .init(command: "-r, --repo", description: "Repository ID. Defaults to $SUPACODE_REPO_ID."),
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
