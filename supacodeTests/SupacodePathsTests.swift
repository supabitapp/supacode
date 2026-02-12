import Foundation
import Testing

@testable import supacode

struct SupacodePathsTests {
  @Test func resolveUsesDefaultWhenNoOverridesExist() {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester")
    let expectedDefault = SupacodePaths.defaultBaseDirectory(homeDirectory: homeDirectory)

    let resolved = SupacodePaths.resolveBaseDirectory(
      environment: [:],
      persistedOverride: nil,
      homeDirectory: homeDirectory
    )

    #expect(resolved.path(percentEncoded: false) == expectedDefault.path(percentEncoded: false))
  }

  @Test func resolveUsesPersistedOverrideWhenEnvironmentIsMissing() {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester")

    let resolved = SupacodePaths.resolveBaseDirectory(
      environment: [:],
      persistedOverride: "  /tmp/supacode-custom  ",
      homeDirectory: homeDirectory
    )

    #expect(resolved.path(percentEncoded: false) == "/tmp/supacode-custom")
  }

  @Test func resolvePrioritizesEnvironmentOverride() {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester")

    let resolved = SupacodePaths.resolveBaseDirectory(
      environment: [SupacodePaths.homeOverrideEnvironmentKey: "/tmp/supacode-env"],
      persistedOverride: "/tmp/supacode-persisted",
      homeDirectory: homeDirectory
    )

    #expect(resolved.path(percentEncoded: false) == "/tmp/supacode-env")
  }

  @Test func resolveFallsBackToPersistedOverrideWhenEnvironmentOverrideIsInvalid() {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester")

    let resolved = SupacodePaths.resolveBaseDirectory(
      environment: [SupacodePaths.homeOverrideEnvironmentKey: "relative/path"],
      persistedOverride: "/tmp/supacode-persisted",
      homeDirectory: homeDirectory
    )

    #expect(resolved.path(percentEncoded: false) == "/tmp/supacode-persisted")
  }

  @Test func resolveExpandsTildeAgainstProvidedHomeDirectory() {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester")

    let resolved = SupacodePaths.resolveBaseDirectory(
      environment: [:],
      persistedOverride: "~/.config/supacode",
      homeDirectory: homeDirectory
    )

    #expect(resolved.path(percentEncoded: false) == "/Users/tester/.config/supacode")
  }

  @Test func resolveFallsBackToDefaultWhenPersistedOverrideIsInvalid() {
    let homeDirectory = URL(fileURLWithPath: "/Users/tester")
    let expectedDefault = SupacodePaths.defaultBaseDirectory(homeDirectory: homeDirectory)

    let resolved = SupacodePaths.resolveBaseDirectory(
      environment: [:],
      persistedOverride: "relative/path",
      homeDirectory: homeDirectory
    )

    #expect(resolved.path(percentEncoded: false) == expectedDefault.path(percentEncoded: false))
  }
}
