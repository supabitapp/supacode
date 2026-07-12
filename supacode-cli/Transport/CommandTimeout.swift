import Foundation

/// Shared timeout policy for CLI socket calls.
nonisolated enum CommandTimeout {
  /// Default seconds to wait for the app to finish an operation.
  static let defaultSeconds = 180
  /// Extra seconds the CLI waits beyond the app's hold budget so the app's
  /// own timeout-error reply arrives before the CLI's read times out.
  static let graceSeconds = 5

  /// Seconds for the CLI's socket read timeout. `0` (or negative) means block
  /// until EOF (wait indefinitely).
  static func readTimeoutSeconds(_ timeout: Int) -> Int {
    timeout <= 0 ? 0 : timeout + graceSeconds
  }

  /// Appends `timeout=<seconds>` to a deeplink URL as a query item so the app
  /// can bound how long it holds the connection open.
  static func embed(_ timeout: Int, in deeplinkURL: String) -> String {
    let value = max(timeout, 0)
    let separator = deeplinkURL.contains("?") ? "&" : "?"
    return "\(deeplinkURL)\(separator)timeout=\(value)"
  }
}
