import ArgumentParser

struct OpenCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Bring Supacode to the front."
  )

  func run() throws {
    try Dispatcher.dispatch(deeplinkURL: DeeplinkURLBuilder.open())
  }
}
