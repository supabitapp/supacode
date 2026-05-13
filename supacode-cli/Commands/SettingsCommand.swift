import ArgumentParser

struct SettingsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "settings",
    abstract: "Open Supacode settings.",
    subcommands: [
      General.self,
      Notifications.self,
      Worktrees.self,
      Developer.self,
      Shortcuts.self,
      Scripts.self,
      Updates.self,
      Github.self,
      Repo.self,
    ]
  )

  func run() throws {
    try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.settings(section: nil))
  }
}

extension SettingsCommand {
  /// Raw values must match `Deeplink.DeeplinkSettingsSection` on the app side.
  fileprivate enum Section: String {
    case general
    case notifications
    case worktrees
    case developer
    case shortcuts
    case scripts
    case updates
    case github
  }

  struct General: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open General settings.")
    func run() throws { try dispatchSettings(.general) }
  }

  struct Notifications: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Notifications settings.")
    func run() throws { try dispatchSettings(.notifications) }
  }

  struct Worktrees: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Worktrees settings.")
    func run() throws { try dispatchSettings(.worktrees) }
  }

  struct Developer: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Developer settings.")
    func run() throws { try dispatchSettings(.developer) }
  }

  struct Shortcuts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Shortcuts settings.")
    func run() throws { try dispatchSettings(.shortcuts) }
  }

  struct Scripts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Global Scripts settings.")
    func run() throws { try dispatchSettings(.scripts) }
  }

  struct Updates: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Updates settings.")
    func run() throws { try dispatchSettings(.updates) }
  }

  struct Github: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open GitHub settings.")
    func run() throws { try dispatchSettings(.github) }
  }

  struct Repo: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Open repository-specific settings.",
      subcommands: [Scripts.self]
    )

    @OptionGroup var options: RepoIDOptions

    func run() throws {
      let rID = try resolveRepoID(options.repo)
      try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.settingsRepo(repoID: rID))
    }

    struct Scripts: ParsableCommand {
      static let configuration = CommandConfiguration(abstract: "Open repository Scripts settings.")

      @OptionGroup var options: RepoIDOptions

      func run() throws {
        let rID = try resolveRepoID(options.repo)
        try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.settingsRepoScripts(repoID: rID))
      }
    }
  }
}

/// Shared via `@OptionGroup` so the parent's `--repo` doesn't shadow the child's.
struct RepoIDOptions: ParsableArguments {
  @Option(name: [.short, .long], help: "Repository ID. Defaults to $SUPACODE_REPO_ID.")
  var repo: String?
}

private nonisolated func dispatchSettings(_ section: SettingsCommand.Section) throws {
  try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.settings(section: section.rawValue))
}
