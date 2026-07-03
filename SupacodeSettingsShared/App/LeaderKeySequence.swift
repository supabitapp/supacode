import Foundation

// Model for the leader-key / multi-key sequence feature.
//
// A `LeaderKeyConfig` is one optional slice of `GlobalSettings`: a leader chord
// plus an ordered list of `LeaderKeySequence`s. Each sequence is a non-empty list
// of continuation key strokes that, pressed after the leader, fire one action.
//
// v1 scope is "Foundation only": a sequence may target ONLY a Ghostty built-in
// action that the existing surface bridge already routes to host behavior (the
// closed `GhosttyLeaderAction` set). The target is modeled as the extensible
// `LeaderActionTarget` sum type so a future host-routable app action can slot in
// additively without breaking already-persisted sequences.

// MARK: - Single continuation key stroke.

// One key in a sequence: a key code plus the optional modifier flags held with it.
// Continuation keys are typically unmodified, so `modifiers` is optional.
public nonisolated struct SequenceKeyStroke: Codable, Equatable, Sendable {
  public var keyCode: UInt16
  public var modifiers: AppShortcutOverride.ModifierFlags?

  public init(keyCode: UInt16, modifiers: AppShortcutOverride.ModifierFlags? = nil) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  // Reuses the single-chord symbol mapping so sequence labels match the rest of
  // the shortcuts UI; no duplicate symbol logic is introduced here.
  public var displaySymbols: [String] {
    AppShortcutOverride.displaySymbols(for: keyCode, modifiers: modifiers ?? [])
  }

  public var displayString: String {
    displaySymbols.joined()
  }

  // The Ghostty keybind token for this single stroke (e.g. `w`, `shift+c`).
  // Sequences join these with `>` when lowered to Ghostty's key-sequence engine.
  // Reuses `AppShortcutOverride.ghosttyKeybind` so the modifier mapping stays in
  // one place.
  public var ghosttyKeybindToken: String {
    AppShortcutOverride(keyCode: keyCode, modifiers: modifiers ?? []).ghosttyKeybind
  }
}

// MARK: - Split directions.

// Direction tokens for `new_split` / `resize_split`. Raw values intentionally
// match the Ghostty keybind grammar so `ghosttyToken` is the raw value.
public nonisolated enum SplitDirection: String, Codable, Equatable, Sendable, CaseIterable {
  case up
  case down
  case left
  case right

  public var ghosttyToken: String { rawValue }

  public var displayName: String {
    switch self {
    case .up: "Up"
    case .down: "Down"
    case .left: "Left"
    case .right: "Right"
    }
  }
}

// Direction tokens for `goto_split`, which also supports relative focus movement.
// Raw values match the Ghostty keybind grammar.
public nonisolated enum SplitFocusDirection: String, Codable, Equatable, Sendable, CaseIterable {
  case previous
  case next
  case up
  case down
  case left
  case right

  public var ghosttyToken: String { rawValue }

  public var displayName: String {
    switch self {
    case .previous: "Previous"
    case .next: "Next"
    case .up: "Up"
    case .down: "Down"
    case .left: "Left"
    case .right: "Right"
    }
  }
}

// MARK: - Ghostty built-in actions.

// The closed set of Ghostty built-in actions a v1 leader sequence can fire.
// Every case here is already routed to host behavior by `GhosttySurfaceBridge`
// (new_tab / close_tab / goto_tab / move_tab / toggle_command_palette / splits).
// Menu-only app actions are deliberately NOT representable here, so a sequence
// can never be bound to an action that would silently no-op.
public nonisolated enum GhosttyLeaderAction: Codable, Equatable, Sendable {
  case newTab
  case closeTab
  case gotoTab(index: Int)
  case moveTab(offset: Int)
  case toggleCommandPalette
  case newSplit(direction: SplitDirection)
  case gotoSplit(direction: SplitFocusDirection)
  case resizeSplit(direction: SplitDirection, amount: UInt16)
  case equalizeSplits
  case toggleSplitZoom

  // The Ghostty keybind action string this action lowers to. Parameterized
  // strings are pinned against Ghostty's keybind grammar.
  public var ghosttyActionString: String {
    switch self {
    case .newTab: "new_tab"
    case .closeTab: "close_tab"
    case .gotoTab(let index): "goto_tab:\(index)"
    case .moveTab(let offset): "move_tab:\(offset)"
    case .toggleCommandPalette: "toggle_command_palette"
    case .newSplit(let direction): "new_split:\(direction.ghosttyToken)"
    case .gotoSplit(let direction): "goto_split:\(direction.ghosttyToken)"
    case .resizeSplit(let direction, let amount): "resize_split:\(direction.ghosttyToken),\(amount)"
    case .equalizeSplits: "equalize_splits"
    case .toggleSplitZoom: "toggle_split_zoom"
    }
  }

  // Human-readable label for the Settings target picker and tooltips.
  public var displayName: String {
    switch self {
    case .newTab: "New Tab"
    case .closeTab: "Close Tab"
    case .gotoTab(let index): "Jump to Worktree \(index)"
    case .moveTab(let offset): "Move Tab by \(offset)"
    case .toggleCommandPalette: "Toggle Command Palette"
    case .newSplit(let direction): "New Split \(direction.displayName)"
    case .gotoSplit(let direction): "Focus \(direction.displayName) Split"
    case .resizeSplit(let direction, let amount): "Resize Split \(direction.displayName) by \(amount)"
    case .equalizeSplits: "Equalize Splits"
    case .toggleSplitZoom: "Toggle Split Zoom"
    }
  }
}

// MARK: - Action target (extensible sum type).

// What a sequence fires. v1 carries only `.ghostty(...)`; the type is an
// extensible sum so a future host-routable app action can be added as a new
// case (e.g. `.appShortcut(AppShortcutID)`) without changing the persisted wire
// format. Decode of an unknown target kind throws, so a forward-compat entry is
// lossy-dropped by the enclosing `sequences` array rather than failing launch.
public nonisolated enum LeaderActionTarget: Codable, Equatable, Sendable {
  case ghostty(GhosttyLeaderAction)

  // The Ghostty built-in this target resolves to, or `nil` for any future
  // non-Ghostty target. Lowering and the picker key off this.
  public var ghosttyAction: GhosttyLeaderAction? {
    switch self {
    case .ghostty(let action): action
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case ghostty
  }

  // Discriminator persisted as `kind`. An unknown raw value (a future case
  // written by a newer build) fails to decode and is dropped upstream.
  private enum Kind: String, Codable {
    case ghostty
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .ghostty:
      self = .ghostty(try container.decode(GhosttyLeaderAction.self, forKey: .ghostty))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .ghostty(let action):
      try container.encode(Kind.ghostty, forKey: .kind)
      try container.encode(action, forKey: .ghostty)
    }
  }
}

// MARK: - One leader sequence.

// An ordered, non-empty list of continuation strokes bound to one target.
// A decoded sequence with an empty stroke list is treated as malformed and
// dropped by the enclosing `sequences` array.
public nonisolated struct LeaderKeySequence: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var keyStrokes: [SequenceKeyStroke]
  public var target: LeaderActionTarget

  public init(id: UUID = UUID(), keyStrokes: [SequenceKeyStroke], target: LeaderActionTarget) {
    self.id = id
    self.keyStrokes = keyStrokes
    self.target = target
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case keyStrokes
    case target
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    let keyStrokes = try container.decode([SequenceKeyStroke].self, forKey: .keyStrokes)
    guard !keyStrokes.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .keyStrokes,
        in: container,
        debugDescription: "A leader sequence must have at least one key stroke.",
      )
    }
    self.keyStrokes = keyStrokes
    self.target = try container.decode(LeaderActionTarget.self, forKey: .target)
  }
}

// MARK: - Full leader configuration.

// The persisted leader-key slice: the leader chord plus its sequences. Optional
// on `GlobalSettings`; absent means no leader is configured. Malformed sequence
// entries are dropped on decode while valid ones survive.
public nonisolated struct LeaderKeyConfig: Codable, Equatable, Sendable {
  public var leaderChord: AppShortcutOverride
  public var sequences: [LeaderKeySequence]

  public init(leaderChord: AppShortcutOverride, sequences: [LeaderKeySequence] = []) {
    self.leaderChord = leaderChord
    self.sequences = sequences
  }

  private enum CodingKeys: String, CodingKey {
    case leaderChord
    case sequences
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.leaderChord = try container.decode(AppShortcutOverride.self, forKey: .leaderChord)
    self.sequences = container.decodeLossyArrayIfPresent(forKey: .sequences) ?? []
  }
}
