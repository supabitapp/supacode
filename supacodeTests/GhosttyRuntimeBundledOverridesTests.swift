import Foundation
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct GhosttyRuntimeBundledOverridesTests {
  // The window tint + appearance source must track the resolved color scheme:
  // a dark scheme yields a dark background, a light scheme a light one. Guards
  // that the bundled themes actually differ so a missing embed hard-fails
  // instead of passing vacuously (both sides would be `windowBackgroundColor`).
  @Test func backgroundColorTracksColorScheme() throws {
    let runtime = GhosttyRuntime(initialColorScheme: .light)
    let light = runtime.backgroundColor()
    runtime.setColorScheme(.dark)
    let dark = runtime.backgroundColor()
    try #require(!light.matchesTint(dark))
    #expect(light.isLightColor)
    #expect(!dark.isLightColor)
    // Re-resolution works in both directions, not just the first transition.
    runtime.setColorScheme(.light)
    #expect(runtime.backgroundColor().isLightColor)
  }

  // The launch-flash fix: `init` seeds the resolved scheme so the FIRST
  // `backgroundColor()` / `windowTintColor()` read (before any further
  // `setColorScheme`) is already scheme-correct, not Ghostty's default-light
  // resolution. Asserting with no interim `setColorScheme` also documents that
  // the seed's config swap lands synchronously within `init`.
  @Test func initSeedsResolvedColorSchemeBeforeFirstRead() {
    let dark = GhosttyRuntime(initialColorScheme: .dark)
    #expect(!dark.backgroundColor().isLightColor)
    #expect(!dark.windowTintColor().isLightColor)
    // With no focused-surface provider installed (the launch state),
    // `windowTintColor()` falls through to exactly `backgroundColor()`.
    #expect(dark.windowTintColor().matchesTint(dark.backgroundColor()))
    let light = GhosttyRuntime(initialColorScheme: .light)
    #expect(light.backgroundColor().isLightColor)
    #expect(light.windowTintColor().isLightColor)
  }

  /// Shell integration must NOT be disabled in the bundled overrides: surfaces
  /// run the real shell with zmx injected as a `command-wrapper`, so Ghostty
  /// integrates the shell exactly as without zmx. Forcing `none` here would
  /// regress OSC 7 cwd reporting (the whole point of the wrapper approach).
  @Test func bundledOverridesDoNotTouchShellIntegration() {
    #expect(!GhosttyRuntime.bundledOverridesString.contains("shell-integration"))
  }

  @Test func bundledOverridesKeepSurfaceCloseDetectionEnabled() {
    #expect(GhosttyRuntime.bundledOverridesString.contains("confirm-close-surface = true"))
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
