import Foundation

/// Fixed fallback directories appended to a wrapper shell's `PATH` so brew and
/// other CLI tools resolve under the non-interactive login shell (`$SHELL -l -c`,
/// see `SSHCommand.loginShellWrapped`), which skips the interactive rc files
/// where Linux Homebrew writes `brew shellenv` (#671). Pure data with no I/O:
/// missing dirs are inert, and a remote host's filesystem is invisible here.
public nonisolated enum WellKnownToolDirectories {
  /// Absolute tool directories, safe to embed as shell literals. One
  /// cross-platform list: each host ignores the entries it lacks.
  public static let absolute = [
    "/opt/homebrew/bin",  // macOS Apple Silicon Homebrew.
    "/usr/local/bin",  // macOS Intel Homebrew / common install prefix.
    "/opt/local/bin",  // macOS MacPorts.
    "/home/linuxbrew/.linuxbrew/bin",  // Linux shared Homebrew (#671).
  ]

  /// Per-user `$HOME`-relative suffixes (no leading slash). Left unexpanded so
  /// the executing shell uses its own `HOME` and drops them when it is unset.
  public static let homeRelative = [
    ".linuxbrew/bin",  // Linux per-user Homebrew (#671).
    ".local/bin",  // pip/pipx/user installs.
  ]

  /// An `export PATH=…; ` statement that appends the well-known directories to
  /// the current `PATH`, for prepending to a `command -v …` lookup. Appending
  /// (via `${PATH:+$PATH:}`) keeps an rc-resolved tool's own precedence; the
  /// `${…:+}` guards avoid a leading colon on empty `PATH` (which would put the
  /// CWD on `PATH`) and a bare `/.linuxbrew/bin` on unset `HOME`. `$PATH` /
  /// `$HOME` survive outer single-quote wrapping unexpanded, for the innermost
  /// shell to expand. Mirrors `GitClient.pathAugmentedInvocation` (#663).
  public static var pathExportPrefix: String {
    let fixed = SSHCommand.shellQuote(absolute.joined(separator: ":"))
    let home = homeRelative.map { "$HOME/\($0)" }.joined(separator: ":")
    return "export PATH=\"${PATH:+$PATH:}\"\(fixed)\"${HOME:+:\(home)}\"; "
  }
}

// NOTE: GitClient / GithubCLIClient carry their own narrower tool lists; a
// follow-up can migrate them here to close the same gap for git-lfs and gh.
