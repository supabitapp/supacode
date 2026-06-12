import Foundation
import Testing

@testable import supacode

@MainActor
struct GhosttyRuntimeBundledOverridesTests {
  /// Shell integration must NOT be disabled in the bundled overrides: surfaces
  /// run the real shell with zmx injected as a `command-wrapper`, so Ghostty
  /// integrates the shell exactly as without zmx. Forcing `none` here would
  /// regress OSC 7 cwd reporting (the whole point of the wrapper approach).
  @Test func bundledOverridesDoNotTouchShellIntegration() {
    #expect(!GhosttyRuntime.bundledOverridesString.contains("shell-integration"))
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
