import ArgumentParser

@main
struct SupacodeCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "supacode",
    abstract: "Control Supacode from the command line.",
    subcommands: [
      OpenCommand.self,
      WorktreeCommand.self,
      TabCommand.self,
      SurfaceCommand.self,
      RepoCommand.self,
      SettingsCommand.self,
      SocketCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
