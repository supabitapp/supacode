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

  /// `TERM_PROGRAM` reports Supacode with its version (issue #440).
  @Test func terminalProgramOverridesIdentifySupacode() {
    let overrides = GhosttyRuntime.terminalProgramOverrides(version: "1.2.3")
    #expect(overrides.contains("env = TERM_PROGRAM=supacode"))
    #expect(overrides.contains("env = TERM_PROGRAM_VERSION=1.2.3"))
  }

  /// A missing or blank version still emits a placeholder, never Ghostty's.
  @Test func terminalProgramOverridesFallBackWhenVersionUnavailable() {
    for version: String? in [nil, "", "   "] {
      let overrides = GhosttyRuntime.terminalProgramOverrides(version: version)
      #expect(overrides.contains("env = TERM_PROGRAM=supacode"))
      #expect(overrides.contains("env = TERM_PROGRAM_VERSION=unknown"))
    }
  }

  /// Surrounding whitespace is trimmed from the emitted version.
  @Test func terminalProgramOverridesTrimVersionWhitespace() {
    let overrides = GhosttyRuntime.terminalProgramOverrides(version: " 1.2.3 ")
    #expect(overrides.contains("env = TERM_PROGRAM_VERSION=1.2.3"))
  }

  @Test func terminalProgramOverridesAreKeyValueDirectives() {
    let lines = GhosttyRuntime.terminalProgramOverrides(version: "9.9.9")
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    #expect(!lines.isEmpty)
    for line in lines {
      #expect(line.contains("="), "Override line missing `=`: \(line)")
    }
  }
}
