import Carbon.HIToolbox
import CustomDump
import Foundation
import Testing

@testable import SupacodeSettingsShared

// Covers the persisted leader-key model (T1): Codable round-trip for the config,
// sequence, stroke, and target types; the lossy-decode contract that drops a
// single malformed `sequences` entry while keeping the valid ones; and the
// foundation-scope guarantee that only a `GhosttyLeaderAction` is a representable
// / lowerable target.
@MainActor
struct LeaderKeySequenceTests {
  // MARK: - Helpers.

  // A leader chord (⌘K) used as the anchor for the round-trip fixtures.
  private static let leaderChord = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])

  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }

  // MARK: - Codable round-trip.

  @Test func sequenceKeyStrokeRoundTripsWithAndWithoutModifiers() throws {
    let unmodified = SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W))
    let modified = SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_C), modifiers: [.shift])

    expectNoDifference(try roundTrip(unmodified), unmodified)
    expectNoDifference(try roundTrip(modified), modified)
  }

  @Test func leaderActionTargetRoundTripsForEveryParameterizedCase() throws {
    let targets: [LeaderActionTarget] = [
      .ghostty(.newTab),
      .ghostty(.closeTab),
      .ghostty(.gotoTab(index: 3)),
      .ghostty(.moveTab(offset: -1)),
      .ghostty(.toggleCommandPalette),
      .ghostty(.newSplit(direction: .right)),
      .ghostty(.gotoSplit(direction: .previous)),
      .ghostty(.resizeSplit(direction: .down, amount: 10)),
      .ghostty(.equalizeSplits),
      .ghostty(.toggleSplitZoom),
    ]

    for target in targets {
      expectNoDifference(try roundTrip(target), target)
    }
  }

  @Test func leaderKeySequenceRoundTripsPreservingIDStrokesAndTarget() throws {
    let sequence = LeaderKeySequence(
      keyStrokes: [
        SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W)),
        SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_C)),
      ],
      target: .ghostty(.toggleCommandPalette),
    )

    let decoded = try roundTrip(sequence)
    expectNoDifference(decoded, sequence)
    // The stable id must survive the round-trip so edit/upsert by id keeps working.
    #expect(decoded.id == sequence.id)
  }

  @Test func leaderKeyConfigRoundTripsLeaderChordAndSequences() throws {
    let config = LeaderKeyConfig(
      leaderChord: Self.leaderChord,
      sequences: [
        LeaderKeySequence(keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_T))], target: .ghostty(.newTab)),
        LeaderKeySequence(
          keyStrokes: [
            SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_S)),
            SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_L)),
          ],
          target: .ghostty(.newSplit(direction: .left)),
        ),
      ],
    )

    expectNoDifference(try roundTrip(config), config)
  }

  // MARK: - Lossy decode (malformed entry dropped, valid ones survive).

  @Test func malformedSequenceEntryIsDroppedWhileValidEntriesSurvive() throws {
    // The middle entry has an empty `keyStrokes` array, which `LeaderKeySequence`
    // rejects on decode; the enclosing `sequences` array must drop only that
    // entry and keep the two valid ones (REQ-006).
    let json = """
      {
        "leaderChord": \(try Self.leaderChordJSON()),
        "sequences": [
          { "keyStrokes": [{ "keyCode": 17 }], "target": { "kind": "ghostty", "ghostty": { "newTab": {} } } },
          { "keyStrokes": [], "target": { "kind": "ghostty", "ghostty": { "newTab": {} } } },
          { "keyStrokes": [{ "keyCode": 1 }], "target": { "kind": "ghostty", "ghostty": { "closeTab": {} } } }
        ]
      }
      """

    let config = try JSONDecoder().decode(LeaderKeyConfig.self, from: Data(json.utf8))

    #expect(config.sequences.count == 2)
    expectNoDifference(config.sequences.map(\.target), [.ghostty(.newTab), .ghostty(.closeTab)])
  }

  @Test func unknownTargetKindDropsThatEntryNotTheWholeConfig() throws {
    // A sequence whose target carries an unknown discriminator (a case a future
    // build might write) fails to decode; only that entry is dropped, the valid
    // one survives, and launch is never aborted (D11 forward-compat seam).
    let json = """
      {
        "leaderChord": \(try Self.leaderChordJSON()),
        "sequences": [
          { "keyStrokes": [{ "keyCode": 17 }], "target": { "kind": "appShortcut", "appShortcut": "newWorktree" } },
          { "keyStrokes": [{ "keyCode": 1 }], "target": { "kind": "ghostty", "ghostty": { "closeTab": {} } } }
        ]
      }
      """

    let config = try JSONDecoder().decode(LeaderKeyConfig.self, from: Data(json.utf8))

    #expect(config.sequences.count == 1)
    expectNoDifference(config.sequences.first?.target, .ghostty(.closeTab))
  }

  @Test func emptyKeyStrokesSequenceDecodeThrows() throws {
    // Direct decode of a single sequence with no strokes throws (it is the
    // `Lossy` wrapper that turns this throw into a dropped array element).
    let json = """
      { "keyStrokes": [], "target": { "kind": "ghostty", "ghostty": { "newTab": {} } } }
      """

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(LeaderKeySequence.self, from: Data(json.utf8))
    }
  }

  @Test func unknownTargetKindDecodeThrows() throws {
    let json = """
      { "kind": "appShortcut", "appShortcut": "newWorktree" }
      """

    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(LeaderActionTarget.self, from: Data(json.utf8))
    }
  }

  // MARK: - Foundation-scope target representability.

  @Test func onlyGhosttyTargetsAreRepresentableAndLowerable() {
    // The v1 target sum type exposes exactly one constructor (`.ghostty`), and
    // every value resolves to a concrete Ghostty built-in via `ghosttyAction`.
    // There is no way to express a menu-only app action, so a sequence can never
    // be bound to a target that would silently no-op (HYP-001 / D2).
    let target = LeaderActionTarget.ghostty(.gotoTab(index: 2))
    #expect(target.ghosttyAction == .gotoTab(index: 2))
  }

  // MARK: - Parameterized action grammar pins.

  @Test func ghosttyActionStringsArePinnedToKeybindGrammar() {
    let cases: [(GhosttyLeaderAction, String)] = [
      (.newTab, "new_tab"),
      (.closeTab, "close_tab"),
      (.gotoTab(index: 4), "goto_tab:4"),
      (.moveTab(offset: -1), "move_tab:-1"),
      (.toggleCommandPalette, "toggle_command_palette"),
      (.newSplit(direction: .up), "new_split:up"),
      (.newSplit(direction: .right), "new_split:right"),
      (.gotoSplit(direction: .previous), "goto_split:previous"),
      (.gotoSplit(direction: .next), "goto_split:next"),
      (.resizeSplit(direction: .down, amount: 10), "resize_split:down,10"),
      (.equalizeSplits, "equalize_splits"),
      (.toggleSplitZoom, "toggle_split_zoom"),
    ]

    for (action, expected) in cases {
      #expect(action.ghosttyActionString == expected)
    }
  }

  // MARK: - JSON fixtures.

  // The encoded leader chord, reused inside the hand-written `sequences` JSON
  // fixtures so the malformed-entry tests exercise the real `AppShortcutOverride`
  // decode path rather than a hard-coded chord shape.
  private static func leaderChordJSON() throws -> String {
    let data = try JSONEncoder().encode(leaderChord)
    return try #require(String(bytes: data, encoding: .utf8))
  }
}
