import Foundation

/// The single source of truth for the fixed directories where CLI tools land
/// when a *non-interactive login shell* misses them on `PATH`.
///
/// Supacode runs remote (and some local) commands through `$SHELL -l -c …`
/// (see `SSHCommand.loginShellWrapped`). That is a login **but
/// non-interactive** shell, so it sources `.zprofile` / `.zlogin` /
/// `.bash_profile` but never the interactive rc files (`.zshrc` / `.bashrc`).
/// Tool managers place their `PATH` setup inconsistently across those files:
///
///   - Homebrew on **macOS** writes `eval "$(brew shellenv)"` to `~/.zprofile`
///     (a login file) → tools resolve in the wrapper.
///   - Homebrew on **Linux** writes it to `~/.bashrc` / `~/.zshrc`
///     (interactive-only) → tools are OFF `PATH` in the wrapper even though an
///     interactive SSH session finds them. This is the exact failure in
///     issue #671 (brew-installed `zmx` on an immutable Linux host is "not
///     detected").
///
/// Rather than depend on where the user placed `brew shellenv`, callers append
/// these fixed prefixes to the wrapper's `PATH`. Appending (not prepending)
/// keeps an rc-resolvable tool's own precedence — the user's version still
/// wins — with the fixed dirs acting purely as a fallback.
///
/// This is intentionally **pure data + pure renderers**, not a
/// `@DependencyClient`: it does no I/O and never varies, so there is nothing to
/// control in tests. Existence of a directory is deliberately NOT checked —
/// the executing shell simply ignores a missing `PATH` entry, and for a remote
/// host the local process cannot see the remote filesystem anyway. Keeping it
/// pure makes it trivially unit-testable with no `FileManager` dependency.
public nonisolated enum WellKnownToolDirectories {
  /// Fully-qualified directories, safe to embed as literals in any shell.
  /// Cross-platform on purpose: a macOS host ignores the linuxbrew entry and a
  /// Linux host ignores the macOS ones, so one list serves every execution
  /// host. Ordered most- to least-specific.
  public static let absolute = [
    "/opt/homebrew/bin",  // macOS Apple Silicon Homebrew
    "/usr/local/bin",  // macOS Intel Homebrew / common install prefix
    "/opt/local/bin",  // macOS MacPorts
    "/home/linuxbrew/.linuxbrew/bin",  // Linux shared Homebrew (#671)
  ]

  /// Per-user directory suffixes under `$HOME`. Left for the *executing* shell
  /// to expand (so a remote host uses its own `HOME`, and the entry drops when
  /// `HOME` is unset) rather than baked against the local process's `HOME`.
  public static let homeRelative = [
    ".linuxbrew/bin",  // Linux per-user Homebrew (#671)
    ".local/bin",  // pip/pipx/user installs
  ]

  /// A `export PATH=…; ` statement that appends the well-known directories to
  /// the current shell's `PATH`, for prepending to a script that then looks up
  /// a tool (`command -v …`) and runs it. Mirrors the quoting idiom already
  /// used by `GitClient.pathAugmentedInvocation` (#663):
  ///
  ///   - `${PATH:+$PATH:}` prefixes the existing `PATH` only when set, so an
  ///     empty `PATH` never yields a leading colon (which would silently put
  ///     the CWD on `PATH`).
  ///   - The absolute dirs are single-quoted literals.
  ///   - `${HOME:+:$HOME/…}` appends the per-user dirs only when `HOME` is set.
  ///
  /// `$PATH` / `$HOME` are intended for expansion by whichever shell ultimately
  /// runs the statement, so this string survives outer single-quote wrapping
  /// (e.g. `loginShellWrapped` / `posixShellWrapped`) unexpanded.
  public static func pathExportPrefix() -> String {
    let fixed = SSHCommand.shellQuote(absolute.joined(separator: ":"))
    let home = homeRelative.map { "$HOME/\($0)" }.joined(separator: ":")
    return "export PATH=\"${PATH:+$PATH:}\"\(fixed)\"${HOME:+:\(home)}\"; "
  }
}

// NOTE: `GitClient.pathAugmentedInvocation` / `gitFilterHelperDirectories` and
// `GithubCLIClient.defaultFallbackExecutableURLs` predate this type and carry
// their own (narrower, linuxbrew-less) hardcoded lists. They should migrate to
// this single source of truth in a follow-up — that also closes the same
// remote-Linux Homebrew gap for `git-lfs` and `gh` that #671 fixed for `zmx`.
