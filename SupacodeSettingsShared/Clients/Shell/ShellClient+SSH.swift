import Foundation

extension ShellClient {
  /// Host-aware transport: a `ShellClient` that runs every command on `host`
  /// over SSH instead of locally, by rewriting each call into an `ssh <host>
  /// <remoteCommand>` invocation (the working directory becomes a remote `cd`)
  /// and delegating to `base` (defaults to `.live`; tests inject a recorder).
  /// This is the single chokepoint that makes the rest of the stack remote. ssh
  /// already runs the remote command through the user's login shell, so the
  /// `runLogin*` entries must not re-wrap it and route to the plain `base.run*`.
  /// `extraOptions` injects per-call `ssh -o` flags (e.g. the non-interactive
  /// background-probe profile) on top of the shared multiplexing options.
  public static func ssh(
    host: RemoteHost,
    base: ShellClient = .live,
    extraOptions: [String] = []
  ) -> ShellClient {
    ShellClient(
      run: { executableURL, arguments, currentDirectoryURL in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL,
          extraOptions: extraOptions
        )
        return try await base.run(invocation.executableURL, invocation.arguments, nil)
      },
      runLoginImpl: { executableURL, arguments, currentDirectoryURL, _ in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL,
          extraOptions: extraOptions
        )
        return try await base.run(invocation.executableURL, invocation.arguments, nil)
      },
      runStream: { executableURL, arguments, currentDirectoryURL in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL,
          extraOptions: extraOptions
        )
        return base.runStream(invocation.executableURL, invocation.arguments, nil)
      },
      runLoginStreamImpl: { executableURL, arguments, currentDirectoryURL, _ in
        let invocation = SSHCommand.invocation(
          host: host,
          executable: executableURL.path(percentEncoded: false),
          arguments: arguments,
          workingDirectory: currentDirectoryURL,
          extraOptions: extraOptions
        )
        return base.runStream(invocation.executableURL, invocation.arguments, nil)
      }
    )
  }
}
