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

  @OptionGroup var timeoutOption: TimeoutOption

  func run() throws {
    try Dispatcher.dispatch(
      deeplinkURL: DeeplinkURLBuilder.settings(section: nil),
      timeoutSeconds: timeoutOption.timeout
    )
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
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.general, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Notifications: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Notifications settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.notifications, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Worktrees: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Worktrees settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.worktrees, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Developer: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Developer settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.developer, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Shortcuts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Shortcuts settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.shortcuts, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Scripts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Global Scripts settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.scripts, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Updates: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open Updates settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.updates, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Github: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open GitHub settings.")
    @OptionGroup var timeoutOption: TimeoutOption
    func run() throws { try dispatchSettings(.github, timeoutSeconds: timeoutOption.timeout) }
  }

  struct Repo: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Open repository-specific settings.",
      subcommands: [Scripts.self]
    )

    @OptionGroup var options: RepoIDOptions
    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let rID = try resolveRepoID(options.repo)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.settingsRepo(repoID: rID),
        timeoutSeconds: timeoutOption.timeout
      )
    }

    struct Scripts: ParsableCommand {
      static let configuration = CommandConfiguration(abstract: "Open repository Scripts settings.")

      @OptionGroup var options: RepoIDOptions
      @OptionGroup var timeoutOption: TimeoutOption

      func run() throws {
        let rID = try resolveRepoID(options.repo)
        try Dispatcher.dispatch(
          deeplinkURL: DeeplinkURLBuilder.settingsRepoScripts(repoID: rID),
          timeoutSeconds: timeoutOption.timeout
        )
      }
    }
  }
}

/// Shared via `@OptionGroup` so the parent's `--repo` doesn't shadow the child's.
struct RepoIDOptions: ParsableArguments {
  @Option(name: [.short, .long], help: "Repository ID. Defaults to $SUPACODE_REPO_ID.")
  var repo: String?
}

private nonisolated func dispatchSettings(_ section: SettingsCommand.Section, timeoutSeconds: Int) throws {
  try Dispatcher.dispatch(
    deeplinkURL: DeeplinkURLBuilder.settings(section: section.rawValue),
    timeoutSeconds: timeoutSeconds
  )
}
