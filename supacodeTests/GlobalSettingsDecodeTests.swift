import Carbon.HIToolbox
import Foundation
import Testing

@testable import SupacodeSettingsShared

// Backward-compatibility coverage for the additive `GlobalSettings.leaderKey`
// field (T2 / REQ-007): an existing settings file that predates the feature has
// no `leaderKey` key at all, so it must decode to `leaderKey == nil` with its
// single-chord `shortcutOverrides` untouched, and a re-encode/decode must be
// stable. Also pins the resilient lossy decode at the `GlobalSettings` level.
@MainActor
struct GlobalSettingsDecodeTests {
  // The three keys `GlobalSettings.init(from:)` requires; everything else falls
  // back to a default when absent, mirroring a minimal pre-feature file.
  private static func legacyJSON(shortcutOverridesJSON: String) -> String {
    """
    {
      "appearanceMode": "dark",
      "updatesAutomaticallyCheckForUpdates": false,
      "updatesAutomaticallyDownloadUpdates": true,
      "shortcutOverrides": \(shortcutOverridesJSON)
    }
    """
  }

  private func encodedJSON(_ value: some Encodable) throws -> String {
    try #require(String(bytes: try JSONEncoder().encode(value), encoding: .utf8))
  }

  // MARK: - Missing leaderKey decodes to nil.

  @Test func oldFileWithoutLeaderKeyDecodesToNilWithSingleChordsIntact() throws {
    let override = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    let overrides: [AppShortcutID: AppShortcutOverride] = [.newWorktree: override]
    let json = Self.legacyJSON(shortcutOverridesJSON: try encodedJSON(overrides))

    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))

    // The feature was absent from the file, so no leader is configured...
    #expect(decoded.leaderKey == nil)
    // ...and the pre-existing single-chord override survives untouched (no migration).
    #expect(decoded.shortcutOverrides == overrides)
  }

  @Test func decodedDefaultLeaderKeyIsNil() throws {
    // A file with no shortcut overrides and no leader key still decodes cleanly.
    let json = Self.legacyJSON(shortcutOverridesJSON: "{}")
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    #expect(decoded.leaderKey == nil)
    #expect(decoded.shortcutOverrides.isEmpty)
  }

  // MARK: - Round-trip stability.

  @Test func leaderKeyRoundTripsThroughGlobalSettings() throws {
    let leader = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    var settings = GlobalSettings.default
    settings.leaderKey = LeaderKeyConfig(
      leaderChord: leader,
      sequences: [
        LeaderKeySequence(
          keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W))],
          target: .ghostty(.newTab),
        )
      ],
    )

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

    #expect(decoded.leaderKey == settings.leaderKey)
  }

  @Test func nilLeaderKeyRoundTripsStable() throws {
    var settings = GlobalSettings.default
    settings.leaderKey = nil

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

    #expect(decoded.leaderKey == nil)
  }

  // MARK: - Resilient lossy decode at the GlobalSettings level.

  @Test func malformedSequenceEntryInLeaderKeyDropsOnlyThatEntry() throws {
    // A hand-edited file with one bad sequence (empty strokes) must not nuke the
    // whole leader config or the valid sequence (REQ-006); the lossy decode lives
    // in `LeaderKeyConfig` and is reached through `GlobalSettings.init(from:)`.
    let leader = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])
    let json = """
      {
        "appearanceMode": "system",
        "updatesAutomaticallyCheckForUpdates": false,
        "updatesAutomaticallyDownloadUpdates": false,
        "leaderKey": {
          "leaderChord": \(try encodedJSON(leader)),
          "sequences": [
            { "keyStrokes": [], "target": { "kind": "ghostty", "ghostty": { "newTab": {} } } },
            { "keyStrokes": [{ "keyCode": 13 }], "target": { "kind": "ghostty", "ghostty": { "closeTab": {} } } }
          ]
        }
      }
      """

    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))

    #expect(decoded.leaderKey?.sequences.count == 1)
    #expect(decoded.leaderKey?.sequences.first?.target == .ghostty(.closeTab))
  }
}
