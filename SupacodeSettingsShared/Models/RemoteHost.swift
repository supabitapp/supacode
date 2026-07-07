import Foundation

/// Describes an SSH destination a worktree can live on. A `nil` `RemoteHost`
/// everywhere means "local": the unchanged Process-on-this-machine path.
///
/// `alias` is whatever `ssh` itself accepts as a host: a `~/.ssh/config` alias
/// or a bare hostname. `username` / `port` are optional overrides for callers
/// that don't want to encode them in ssh config.
public nonisolated struct RemoteHost: Codable, Hashable, Sendable {
  public var alias: String
  public var username: String?
  public var port: Int?

  public init(
    alias: String,
    username: String? = nil,
    port: Int? = nil
  ) {
    self.alias = alias
    self.username = username
    self.port = port
  }

  /// Inverse of `authority`: parse `[user@]host[:port]` back into a host. A
  /// bracketed IPv6 host keeps its colons inside the brackets. `nil` if host empty.
  public init?(authority: String) {
    let trimmed = authority.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let user: String?
    let hostPort: Substring
    if let atIndex = trimmed.lastIndex(of: "@") {
      user = String(trimmed[..<atIndex])
      hostPort = trimmed[trimmed.index(after: atIndex)...]
    } else {
      user = nil
      hostPort = trimmed[...]
    }
    guard !hostPort.isEmpty else { return nil }
    let host: String
    let port: Int?
    if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
      host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
      let after = hostPort[hostPort.index(after: close)...]
      port = after.hasPrefix(":") ? Int(after.dropFirst()) : nil
    } else if let colon = hostPort.lastIndex(of: ":"),
      let parsed = Int(hostPort[hostPort.index(after: colon)...])
    {
      host = String(hostPort[..<colon])
      port = parsed
    } else {
      host = String(hostPort)
      port = nil
    }
    guard !host.isEmpty else { return nil }
    self.init(alias: host, username: (user?.isEmpty ?? true) ? nil : user, port: port)
  }

  /// Whether this host carries a non-default SSH port (22 and `nil` both fold to
  /// `false`). Backs the "VS Code family can't express an inline port" rule.
  public var hasNonDefaultPort: Bool { port != nil && port != 22 }

  /// The `user@host` (or bare `host`) token passed to `ssh`. The host stays bare
  /// even for an IPv6 literal (the ssh CLI wants `user@::1`, not the bracketed
  /// form). A literal argv destination (e.g. VS Code's `ssh-remote+<…>`), NOT a
  /// URL, so it must stay unencoded. The URL-bound counterpart is `sshURLAuthority`.
  public var sshDestination: String {
    if let username, !username.isEmpty {
      return "\(username)@\(alias)"
    }
    return alias
  }

  /// `[user@]host` with an IPv6 literal host bracketed, so a following `:port`
  /// is unambiguous. Backs the id-bearing `authority` / `displayAuthority`, which
  /// must round-trip through `init?(authority:)`; `sshDestination` stays bare for
  /// the ssh CLI.
  private var bracketedDestination: String {
    let host = alias.contains(":") ? "[\(alias)]" : alias
    if let username, !username.isEmpty {
      return "\(username)@\(host)"
    }
    return host
  }

  /// Friendly `[user@]host[:port]` for display: username only when the user set
  /// it, port only when non-default (not 22). The id-bearing `authority` always
  /// includes the port; this is the human-facing variant.
  public var displayAuthority: String {
    guard let port, port != 22 else { return bracketedDestination }
    return "\(bracketedDestination):\(port)"
  }

  /// Percent-encoded `[user@]host[:port]` authority for an `ssh://` URL (Zed's
  /// Remote-SSH CLI). Includes any explicit port (even 22) to match
  /// `sshOptionArguments`' `-p`, brackets an IPv6 host, and encodes userinfo /
  /// host so a special character can't forge a malformed URL. Zed percent-decodes
  /// before invoking ssh, so encoding here is correct.
  public var sshURLAuthority: String {
    // Bracket an IPv6 literal BEFORE encoding: `.urlHostAllowed` keeps `[`, `]`,
    // `:`, so `[::1]` round-trips while a hostname's special chars still encode.
    let bracketedHost = alias.contains(":") ? "[\(alias)]" : alias
    let encodedHost = bracketedHost.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? bracketedHost
    let destination: String
    if let username, !username.isEmpty {
      let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
      destination = "\(encodedUser)@\(encodedHost)"
    } else {
      destination = encodedHost
    }
    guard let port else { return destination }
    return "\(destination):\(port)"
  }

  /// `[user@]host[:port]` token used to brand remote ids and settings keys.
  /// Always folds in the port (unlike `displayAuthority`), so two hosts that
  /// differ only by port get distinct ids. Always shell/url safe.
  public var authority: String {
    guard let port else { return bracketedDestination }
    return "\(bracketedDestination):\(port)"
  }

  /// Extra `ssh` option arguments derived from the host (currently just the
  /// port). Always shell-safe tokens, so callers can splice them into a
  /// command line without quoting.
  public var sshOptionArguments: [String] {
    guard let port else { return [] }
    return ["-p", String(port)]
  }
}
