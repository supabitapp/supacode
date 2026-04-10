import ArgumentParser

/// Valid settings sections for argument validation.
nonisolated enum SettingsSection: String, ExpressibleByArgument, CaseIterable {
  case general
  case notifications
  case worktrees
  case developer
  case shortcuts
  case updates
  case github
}

struct SettingsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "settings",
    abstract: "Open Supacode settings.",
    subcommands: [
      Repo.self,
    ]
  )

  @Argument(help: "Settings section: \(SettingsSection.allCases.map(\.rawValue).joined(separator: ", ")).")
  var section: SettingsSection?

  func run() throws {
    try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.settings(section: section?.rawValue))
  }
}

extension SettingsCommand {
  struct Repo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open repository-specific settings.")

    @Option(name: [.short, .long], help: "Repository ID. Defaults to $SUPACODE_REPO_ID.")
    var repo: String?

    func run() throws {
      let rID = try resolveRepoID(repo)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.settingsRepo(repoID: rID))
    }
  }
}
