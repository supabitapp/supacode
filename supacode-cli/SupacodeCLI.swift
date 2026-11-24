import ArgumentParser

@main
struct SupacodeCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "supacode",
    abstract: "Control Supacode from the command line.",
    subcommands: [
      OpenCommand.self,
      WorktreeCommand.self,
      PaneCommand.self,
      TabCommand.self,
      SurfaceCommand.self,
      BrowserCommand.self,
      RepoCommand.self,
      SettingsCommand.self,
      SocketCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
