import ArgumentParser

@main
struct Tty7CLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tty7",
    abstract: "Control tty7 from the command line.",
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
