/// Where an automated action originated from.
public enum ActionSource: Equatable, Sendable {
  /// Received via the `tty7://` URL scheme (e.g. `open` command, browser).
  case urlScheme
  /// Received via the Unix domain socket (CLI tool).
  case socket
}
