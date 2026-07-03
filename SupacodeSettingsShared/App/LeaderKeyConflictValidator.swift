import Foundation

// Pure, stateless validator for the leader-key / multi-key sequence feature.
//
// Every finding here is a NON-BLOCKING warning: the Settings UI surfaces them so
// the user can fix an ambiguous or unreachable binding, but nothing prevents a
// config from being saved. The validator does no I/O and reads no `@Shared`
// state — the reserved-key set is injected by the caller (which passes
// `AppShortcutOverride.allReservedDisplayStrings()`), so this function is
// deterministic for its inputs and directly unit-testable without touching the
// host's symbolic-hotkeys defaults.
//
// It reuses the existing shortcut display + reserved model: single-chord display
// strings come from `AppShortcuts.all` resolved through the user's overrides
// (the same source `AppShortcuts.conflictWarnings` uses) and stroke symbols come
// from `AppShortcutOverride.displaySymbols`, so labels match the rest of the
// shortcuts UI and no duplicate reserved/symbol list is introduced.

// MARK: - One detected conflict.

// A single conflict, either on the leader chord (config-level) or on one
// sequence. Carries display strings rather than ids so the rendered `message` is
// stable and the UI (T6) can either show the message directly or switch on the
// case for richer presentation (e.g. an icon per kind).
public nonisolated enum LeaderKeyConflict: Equatable, Sendable {
  // This sequence's stroke chain is a proper prefix of `other`, so it fires
  // before the longer sequence can ever complete (genuinely ambiguous under
  // Ghostty's `>` engine).
  case prefixOfAnotherSequence(other: String)
  // `other`'s stroke chain is a proper prefix of this sequence's, so the shorter
  // one fires first and this sequence can never be reached.
  case prefixedByAnotherSequence(other: String)
  // The exact same stroke chain is bound by another sequence.
  case duplicateSequence
  // The sequence's stroke display path equals a live single-chord shortcut, so
  // the same chord means two different things depending on context.
  case collidesWithShortcut(chord: String, shortcut: String)
  // The sequence begins with Escape, which is reserved as the leader-cancel key
  // (the `<leader>escape=end_key_sequence` bind), so it can never fire.
  case usesReservedCancelKey
  // The leader chord is a system-reserved chord.
  case leaderReserved(chord: String)
  // The leader chord equals a live single-chord shortcut.
  case leaderCollidesWithShortcut(chord: String, shortcut: String)

  // User-facing warning text. Concise and phrased like the existing
  // single-chord conflict warnings.
  public var message: String {
    switch self {
    case .prefixOfAnotherSequence(let other):
      "This sequence is a prefix of \(other), so it fires before that sequence can complete."
    case .prefixedByAnotherSequence(let other):
      "\(other) is a prefix of this sequence, so this sequence can never fire."
    case .duplicateSequence:
      "This sequence is already bound to another action."
    case .collidesWithShortcut(let chord, let shortcut):
      "\(chord) is also bound to \(shortcut)."
    case .usesReservedCancelKey:
      "Escape after the leader is reserved to cancel the sequence."
    case .leaderReserved(let chord):
      "\(chord) is reserved by the system."
    case .leaderCollidesWithShortcut(let chord, let shortcut):
      "\(chord) is also bound to \(shortcut)."
    }
  }
}

// MARK: - Validation report.

// The full result of one validation pass. Leader-chord conflicts are reported
// once at the top level (the leader is shared by every sequence); per-sequence
// conflicts are keyed by sequence id so the UI can render a warning under each
// row. A sequence with no conflicts has no entry, so `conflicts(for:)` returns
// an empty array rather than requiring the caller to handle a missing key.
public nonisolated struct LeaderKeyConflictReport: Equatable, Sendable {
  public var leaderConflicts: [LeaderKeyConflict]
  public var sequenceConflicts: [LeaderKeySequence.ID: [LeaderKeyConflict]]

  public init(
    leaderConflicts: [LeaderKeyConflict] = [],
    sequenceConflicts: [LeaderKeySequence.ID: [LeaderKeyConflict]] = [:],
  ) {
    self.leaderConflicts = leaderConflicts
    self.sequenceConflicts = sequenceConflicts
  }

  public var isEmpty: Bool {
    leaderConflicts.isEmpty && sequenceConflicts.isEmpty
  }

  public func conflicts(for sequenceID: LeaderKeySequence.ID) -> [LeaderKeyConflict] {
    sequenceConflicts[sequenceID] ?? []
  }
}

// MARK: - Validator.

public nonisolated enum LeaderKeyConflictValidator {
  // Validates a leader configuration and returns every non-blocking conflict.
  //
  // - Parameters:
  //   - config: the leader configuration to check; `nil` (no leader) yields an
  //     empty report.
  //   - shortcutOverrides: the user's single-chord overrides, used (with the
  //     built-in `AppShortcuts.all` defaults) to compute the live single-chord
  //     display strings a leader chord or sequence might collide with.
  //   - reservedDisplayStrings: system/AppKit reserved chord display strings.
  //     Injected (rather than read here) to keep the validator pure; live
  //     callers pass `AppShortcutOverride.allReservedDisplayStrings()`.
  public static func validate(
    config: LeaderKeyConfig?,
    shortcutOverrides: [AppShortcutID: AppShortcutOverride],
    reservedDisplayStrings: Set<String>,
  ) -> LeaderKeyConflictReport {
    guard let config else { return LeaderKeyConflictReport() }

    let singleChordsByDisplay = singleChordDisplayMap(overrides: shortcutOverrides)

    let leaderConflicts = leaderChordConflicts(
      leaderChord: config.leaderChord,
      singleChordsByDisplay: singleChordsByDisplay,
      reservedDisplayStrings: reservedDisplayStrings,
    )

    var sequenceConflicts: [LeaderKeySequence.ID: [LeaderKeyConflict]] = [:]
    for (sequenceID, conflicts) in sequenceConflictMap(
      sequences: config.sequences,
      leaderChord: config.leaderChord,
      singleChordsByDisplay: singleChordsByDisplay,
    ) where !conflicts.isEmpty {
      // Sort by message so the rendered order is stable regardless of trie
      // traversal order, keeping the UI and tests deterministic.
      sequenceConflicts[sequenceID] = conflicts.sorted { $0.message < $1.message }
    }

    return LeaderKeyConflictReport(
      leaderConflicts: leaderConflicts,
      sequenceConflicts: sequenceConflicts,
    )
  }

  // MARK: - Leader chord.

  private static func leaderChordConflicts(
    leaderChord: AppShortcutOverride,
    singleChordsByDisplay: [String: String],
    reservedDisplayStrings: Set<String>,
  ) -> [LeaderKeyConflict] {
    let display = leaderChord.displayString
    var conflicts: [LeaderKeyConflict] = []
    if reservedDisplayStrings.contains(display) {
      conflicts.append(.leaderReserved(chord: display))
    }
    if let shortcut = singleChordsByDisplay[display] {
      conflicts.append(.leaderCollidesWithShortcut(chord: display, shortcut: shortcut))
    }
    return conflicts
  }

  // MARK: - Sequences.

  private static func sequenceConflictMap(
    sequences: [LeaderKeySequence],
    leaderChord: AppShortcutOverride,
    singleChordsByDisplay: [String: String],
  ) -> [LeaderKeySequence.ID: [LeaderKeyConflict]] {
    var conflicts: [LeaderKeySequence.ID: [LeaderKeyConflict]] = [:]
    func add(_ conflict: LeaderKeyConflict, to sequenceID: LeaderKeySequence.ID) {
      conflicts[sequenceID, default: []].append(conflict)
    }

    let byID = Dictionary(sequences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func displayPath(of sequenceID: LeaderKeySequence.ID) -> String {
      guard let sequence = byID[sequenceID] else { return "" }
      return sequencePathDisplay(sequence, leaderChord: leaderChord)
    }

    // Prefix + duplicate detection via a trie keyed on each stroke's Ghostty
    // token (exactly what the `>` engine matches on, so this mirrors real
    // runtime ambiguity rather than mere visual similarity).
    let trie = SequenceTrie()
    for sequence in sequences where !sequence.keyStrokes.isEmpty {
      trie.insert(tokens: sequence.keyStrokes.map(\.ghosttyKeybindToken), sequenceID: sequence.id)
    }
    for relation in trie.prefixRelations() {
      add(.prefixOfAnotherSequence(other: displayPath(of: relation.longer)), to: relation.shorter)
      add(.prefixedByAnotherSequence(other: displayPath(of: relation.shorter)), to: relation.longer)
    }
    for duplicateID in trie.duplicateSequenceIDs() {
      add(.duplicateSequence, to: duplicateID)
    }

    // Per-sequence collisions independent of other sequences.
    for sequence in sequences where !sequence.keyStrokes.isEmpty {
      let strokePath = sequence.keyStrokes.flatMap(\.displaySymbols).joined()
      if let shortcut = singleChordsByDisplay[strokePath] {
        add(.collidesWithShortcut(chord: strokePath, shortcut: shortcut), to: sequence.id)
      }
      if sequence.keyStrokes.first?.ghosttyKeybindToken == "escape" {
        add(.usesReservedCancelKey, to: sequence.id)
      }
    }

    return conflicts
  }

  // MARK: - Display helpers.

  // Live single-chord shortcut display strings mapped to their action name, from
  // the built-in shortcuts resolved through the user's overrides. A disabled
  // shortcut contributes nothing (its chord is free), matching how the rest of
  // the shortcut system computes effective bindings.
  private static func singleChordDisplayMap(
    overrides: [AppShortcutID: AppShortcutOverride]
  ) -> [String: String] {
    var map: [String: String] = [:]
    for shortcut in AppShortcuts.all {
      guard let effective = shortcut.effective(from: overrides) else { continue }
      map[effective.display] = effective.displayName
    }
    return map
  }

  // The full recognizable chord chain for a sequence, e.g. "⌘K W C".
  private static func sequencePathDisplay(
    _ sequence: LeaderKeySequence,
    leaderChord: AppShortcutOverride,
  ) -> String {
    ([leaderChord.displayString] + sequence.keyStrokes.map(\.displayString)).joined(separator: " ")
  }
}

// MARK: - Trie.

// Minimal prefix tree over sequence stroke-token chains. It is the natural
// structure for "is X a proper prefix of Y" across a set and yields both prefix
// relations and exact duplicates in one build. Used only within a synchronous
// validation pass, so it never crosses a concurrency boundary.
private final class SequenceTrie {
  private final class Node {
    var children: [String: Node] = [:]
    var terminals: [LeaderKeySequence.ID] = []
  }

  // A sequence (`shorter`) whose token chain is a proper prefix of another
  // (`longer`).
  struct PrefixRelation {
    let shorter: LeaderKeySequence.ID
    let longer: LeaderKeySequence.ID
  }

  private let root = Node()

  func insert(tokens: [String], sequenceID: LeaderKeySequence.ID) {
    var node = root
    for token in tokens {
      if let next = node.children[token] {
        node = next
      } else {
        let next = Node()
        node.children[token] = next
        node = next
      }
    }
    node.terminals.append(sequenceID)
  }

  // Every (shorter, longer) pair where the shorter sequence terminates strictly
  // above the longer one along the same chain.
  func prefixRelations() -> [PrefixRelation] {
    var relations: [PrefixRelation] = []
    visit(root) { node in
      guard !node.terminals.isEmpty else { return }
      let descendants = descendantTerminals(of: node)
      for shorter in node.terminals {
        for longer in descendants {
          relations.append(PrefixRelation(shorter: shorter, longer: longer))
        }
      }
    }
    return relations
  }

  // Sequence ids that share an identical token chain with at least one other
  // sequence (i.e. terminate at the same node).
  func duplicateSequenceIDs() -> [LeaderKeySequence.ID] {
    var duplicates: [LeaderKeySequence.ID] = []
    visit(root) { node in
      if node.terminals.count > 1 {
        duplicates.append(contentsOf: node.terminals)
      }
    }
    return duplicates
  }

  private func descendantTerminals(of node: Node) -> [LeaderKeySequence.ID] {
    var result: [LeaderKeySequence.ID] = []
    for child in node.children.values {
      visit(child) { result.append(contentsOf: $0.terminals) }
    }
    return result
  }

  private func visit(_ node: Node, _ body: (Node) -> Void) {
    body(node)
    for child in node.children.values {
      visit(child, body)
    }
  }
}
