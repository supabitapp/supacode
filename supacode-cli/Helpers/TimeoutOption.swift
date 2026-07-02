import ArgumentParser

/// Shared `--timeout` flag mixed into every command that waits on the app.
struct TimeoutOption: ParsableArguments {
  @Option(
    name: [.long],
    help: "Seconds to wait for the operation to complete (0 = wait indefinitely)."
  )
  var timeout: Int = CommandTimeout.defaultSeconds
}
