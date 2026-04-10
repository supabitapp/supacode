/// Where an automated action originated from.
enum ActionSource: Equatable, Sendable {
  /// Received via the `supacode://` URL scheme (e.g. `open` command, browser).
  case urlScheme
  /// Received via the Unix domain socket (CLI tool).
  case socket
}
