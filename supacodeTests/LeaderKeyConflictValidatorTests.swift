import Carbon.HIToolbox
import Foundation
import Testing

@testable import SupacodeSettingsShared

// Covers the pure leader-key conflict validator (T4): prefix / duplicate relations
// over the sequence trie, sequence-vs-single-chord collisions, the Escape
// reserved-cancel-key concern, and leader-chord vs single-chord / reserved
// collisions. Assertions target the Equatable `LeaderKeyConflict` cases rather
// than their rendered messages so they survive copy changes (REQ-005).
@MainActor
struct LeaderKeyConflictValidatorTests {
  // ⌘K leader anchor; its display string is "⌘K".
  private static let leaderChord = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command])

  private func validate(
    _ config: LeaderKeyConfig?,
    overrides: [AppShortcutID: AppShortcutOverride] = [:],
    reserved: Set<String> = [],
  ) -> LeaderKeyConflictReport {
    LeaderKeyConflictValidator.validate(
      config: config,
      shortcutOverrides: overrides,
      reservedDisplayStrings: reserved,
    )
  }

  // MARK: - Prefix collisions.

  @Test func prefixSequenceFlagsBothDirections() {
    // `<leader> w` is a proper prefix of `<leader> w c`, so the shorter fires
    // first (it can never let the longer complete) and the longer can never fire.
    let shorter = LeaderKeySequence(
      keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W))],
      target: .ghostty(.newTab),
    )
    let longer = LeaderKeySequence(
      keyStrokes: [
        SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W)),
        SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_C)),
      ],
      target: .ghostty(.closeTab),
    )

    let report = validate(LeaderKeyConfig(leaderChord: Self.leaderChord, sequences: [shorter, longer]))

    #expect(report.conflicts(for: shorter.id) == [.prefixOfAnotherSequence(other: "⌘K W C")])
    #expect(report.conflicts(for: longer.id) == [.prefixedByAnotherSequence(other: "⌘K W")])
  }

  @Test func exactDuplicateSequenceIsFlaggedOnBoth() {
    let first = LeaderKeySequence(
      keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W))],
      target: .ghostty(.newTab),
    )
    let second = LeaderKeySequence(
      keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W))],
      target: .ghostty(.closeTab),
    )

    let report = validate(LeaderKeyConfig(leaderChord: Self.leaderChord, sequences: [first, second]))

    #expect(report.conflicts(for: first.id) == [.duplicateSequence])
    #expect(report.conflicts(for: second.id) == [.duplicateSequence])
  }

  // MARK: - Sequence vs single chord.

  @Test func sequenceStrokeCollidingWithSingleChordIsFlagged() {
    // A single `⌘N` continuation has the same display path as the built-in
    // New Worktree chord, so the same chord means two things by context.
    let sequence = LeaderKeySequence(
      keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command])],
      target: .ghostty(.newTab),
    )

    let report = validate(LeaderKeyConfig(leaderChord: Self.leaderChord, sequences: [sequence]))

    #expect(report.conflicts(for: sequence.id) == [.collidesWithShortcut(chord: "⌘N", shortcut: "New Worktree")])
  }

  @Test func escapeFirstSequenceFlagsReservedCancelKey() {
    // Escape after the leader is reserved for the auto-bound
    // `<leader>escape=end_key_sequence` cancel, so a sequence starting with
    // Escape can never fire.
    let sequence = LeaderKeySequence(
      keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_Escape))],
      target: .ghostty(.newTab),
    )

    let report = validate(LeaderKeyConfig(leaderChord: Self.leaderChord, sequences: [sequence]))

    #expect(report.conflicts(for: sequence.id) == [.usesReservedCancelKey])
  }

  // MARK: - Leader chord collisions.

  @Test func leaderCollidingWithSingleChordIsFlaggedAtConfigLevel() {
    // ⌘N is the New Worktree chord; choosing it as the leader collides.
    let leader = AppShortcutOverride(keyCode: UInt16(kVK_ANSI_N), modifiers: [.command])

    let report = validate(LeaderKeyConfig(leaderChord: leader, sequences: []))

    #expect(report.leaderConflicts == [.leaderCollidesWithShortcut(chord: "⌘N", shortcut: "New Worktree")])
  }

  @Test func leaderInReservedSetIsFlaggedAtConfigLevel() {
    // The reserved set is injected; passing the leader's own display string in it
    // is the deterministic stand-in for a system/terminal-reserved chord.
    let report = validate(
      LeaderKeyConfig(leaderChord: Self.leaderChord, sequences: []),
      reserved: [Self.leaderChord.displayString],
    )

    #expect(report.leaderConflicts == [.leaderReserved(chord: "⌘K")])
  }

  // MARK: - Clean configurations.

  @Test func nonConflictingConfigurationProducesEmptyReport() {
    let sequence = LeaderKeySequence(
      keyStrokes: [SequenceKeyStroke(keyCode: UInt16(kVK_ANSI_W))],
      target: .ghostty(.newTab),
    )

    let report = validate(LeaderKeyConfig(leaderChord: Self.leaderChord, sequences: [sequence]))

    #expect(report.isEmpty)
    #expect(report.conflicts(for: sequence.id).isEmpty)
  }

  @Test func nilConfigurationProducesEmptyReport() {
    #expect(validate(nil).isEmpty)
  }
}
