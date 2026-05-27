import Foundation
import Testing

@testable import supacode

@MainActor
struct GhosttyRuntimeBundledOverridesTests {
  /// `shell-integration = none` is the actual #356 fix; it must stay in the
  /// bundled overrides so Ghostty's `setupBash` is unreachable and `--posix`
  /// can never be prepended to the surface command. A future refactor that
  /// drops this line reintroduces the crash.
  @Test func bundledOverridesDisableShellIntegration() {
    #expect(GhosttyRuntime.bundledOverridesString.contains("shell-integration = none"))
  }

  /// Each line in the heredoc is parsed as a Ghostty `key = value` directive
  /// by `ghostty_config_load_file`. Catches accidental free-form text edits.
  @Test func bundledOverridesAreKeyValueDirectives() {
    let lines = GhosttyRuntime.bundledOverridesString
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    #expect(!lines.isEmpty)
    for line in lines {
      #expect(line.contains("="), "Override line missing `=`: \(line)")
    }
  }
}
