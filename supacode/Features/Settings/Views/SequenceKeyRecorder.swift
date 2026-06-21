import AppKit
import Carbon.HIToolbox
import SupacodeSettingsShared
import SwiftUI

// Editor + key-capture surface for a single leader-key sequence (leader + ordered
// continuation strokes -> one Ghostty built-in action).
//
// The leader chord itself is captured by the shared `HotkeyRecorderPopover`
// (modifier required, REQ-001). Continuation strokes are different: they are
// typically unmodified mnemonics (`w`, `c`), which that recorder forbids, so this
// file adds a focused recorder that accepts no-modifier keys, uses Escape to
// finish capture, and Backspace to delete the last stroke (design D5).
//
// The target picker offers ONLY the closed `GhosttyLeaderAction` set (the
// host-routable built-ins). Menu-only app actions are deliberately not offered:
// lowered to Ghostty they would silently no-op, so excluding them here is the
// foundation-scope guardrail (HYP-001 / design D2).

// MARK: - Target catalog.

// The concrete, user-selectable `GhosttyLeaderAction` values surfaced by the
// target picker. Which concrete parameters to offer (worktree count, resize
// amount, tab-move offsets) is a UI presentation choice, so it lives here rather
// than on the model. Every entry is a host-routable built-in; labels come from
// `GhosttyLeaderAction.displayName` so they match the rest of the shortcuts UI.
enum GhosttyLeaderActionCatalog {
  // Display grouping for the picker. Raw value is the section header.
  enum Section: String, CaseIterable {
    case tabs = "Tabs"
    case worktrees = "Worktrees"
    case splits = "Splits"
    case commandPalette = "Command Palette"
  }

  static func actions(in section: Section) -> [GhosttyLeaderAction] {
    switch section {
    case .tabs:
      [.newTab, .closeTab, .moveTab(offset: -1), .moveTab(offset: 1)]
    case .worktrees:
      (1...9).map { GhosttyLeaderAction.gotoTab(index: $0) }
    case .splits:
      SplitDirection.allCases.map { GhosttyLeaderAction.newSplit(direction: $0) }
        + SplitFocusDirection.allCases.map { GhosttyLeaderAction.gotoSplit(direction: $0) }
        + SplitDirection.allCases.map { GhosttyLeaderAction.resizeSplit(direction: $0, amount: defaultResizeAmount) }
        + [.equalizeSplits, .toggleSplitZoom]
    case .commandPalette:
      [.toggleCommandPalette]
    }
  }

  // Every offered action, flattened. Used to resolve a picked action string back
  // to its `GhosttyLeaderAction` on save.
  static let all: [GhosttyLeaderAction] = Section.allCases.flatMap { actions(in: $0) }

  // The default split-resize step. A fixed amount keeps the picker a flat list
  // instead of exploding into a per-amount matrix.
  private static let defaultResizeAmount: UInt16 = 10

  // Resolve a picked Ghostty action string back to the catalog entry. The action
  // string is unique per concrete action, so it is a stable picker tag.
  static func action(forActionString actionString: String) -> GhosttyLeaderAction? {
    all.first { $0.ghosttyActionString == actionString }
  }
}

// MARK: - Sequence editor sheet.

// Adds a new sequence or edits an existing one. Owns a local draft (strokes +
// target) so nothing is committed until the user saves; on save it builds a
// `LeaderKeySequence` (preserving the id when editing, so the reducer's upsert
// edits in place) and hands it back to the caller.
struct LeaderSequenceEditorSheet: View {
  // The sequence being edited, or `nil` to create a new one.
  let existing: LeaderKeySequence?
  let onSave: (LeaderKeySequence) -> Void
  let onCancel: () -> Void

  @State private var keyStrokes: [SequenceKeyStroke]
  @State private var selectedActionString: String
  @State private var isCapturing: Bool

  init(
    existing: LeaderKeySequence?,
    onSave: @escaping (LeaderKeySequence) -> Void,
    onCancel: @escaping () -> Void,
  ) {
    self.existing = existing
    self.onSave = onSave
    self.onCancel = onCancel
    _keyStrokes = State(initialValue: existing?.keyStrokes ?? [])
    let initialAction =
      existing?.target.ghosttyAction ?? GhosttyLeaderActionCatalog.all.first ?? .newTab
    _selectedActionString = State(initialValue: initialAction.ghosttyActionString)
    // Start capturing immediately for a new sequence; when editing, the existing
    // strokes are shown and capture appends to them (Backspace / Clear let the
    // user correct).
    _isCapturing = State(initialValue: existing == nil)
  }

  private var canSave: Bool { !keyStrokes.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(existing == nil ? "Add Sequence" : "Edit Sequence")
        .font(.headline)

      VStack(alignment: .leading, spacing: 8) {
        Text("Keys")
          .font(.subheadline.weight(.medium))
        SequenceStrokeField(
          keyStrokes: keyStrokes,
          isCapturing: isCapturing,
          onRecordStroke: { stroke in keyStrokes.append(stroke) },
          onDeleteLast: { _ = keyStrokes.popLast() },
          onFinish: { isCapturing = false },
        )
        HStack(spacing: 8) {
          if isCapturing {
            Text("Press keys in order · ⎋ to finish · ⌫ to delete last")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Button("Record Keys") { isCapturing = true }
              .help("Capture the key strokes pressed after the leader.")
          }
          Spacer()
          Button("Clear") {
            keyStrokes.removeAll()
            isCapturing = true
          }
          .help("Remove all captured key strokes and start over.")
          .disabled(keyStrokes.isEmpty)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Action")
          .font(.subheadline.weight(.medium))
        Picker("Action", selection: $selectedActionString) {
          ForEach(GhosttyLeaderActionCatalog.Section.allCases, id: \.self) { section in
            SwiftUI.Section(section.rawValue) {
              ForEach(GhosttyLeaderActionCatalog.actions(in: section), id: \.ghosttyActionString) { action in
                Text(action.displayName).tag(action.ghosttyActionString)
              }
            }
          }
        }
        .labelsHidden()
        .help("The built-in action this sequence runs. Only host-routable actions are available.")
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { onCancel() }
          .help("Discard this sequence without saving.")
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
          .help("Save this leader sequence.")
      }
    }
    .padding(20)
    .frame(minWidth: 360)
  }

  private func save() {
    guard !keyStrokes.isEmpty else { return }
    let fallback = GhosttyLeaderActionCatalog.all.first ?? .newTab
    let action = GhosttyLeaderActionCatalog.action(forActionString: selectedActionString) ?? fallback
    let sequence = LeaderKeySequence(
      id: existing?.id ?? UUID(),
      keyStrokes: keyStrokes,
      target: .ghostty(action),
    )
    onSave(sequence)
  }
}

// MARK: - Stroke field.

// Renders the captured strokes as keycaps and, while capturing, hosts the
// no-modifier key recorder. Mirrors the keycap presentation of the single-chord
// recorder so sequence labels read consistently.
private struct SequenceStrokeField: View {
  let keyStrokes: [SequenceKeyStroke]
  let isCapturing: Bool
  let onRecordStroke: (SequenceKeyStroke) -> Void
  let onDeleteLast: () -> Void
  let onFinish: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      if keyStrokes.isEmpty {
        Text("No keys recorded")
          .foregroundStyle(.tertiary)
      } else {
        ForEach(Array(keyStrokes.enumerated()), id: \.offset) { _, stroke in
          ForEach(Array(stroke.displaySymbols.enumerated()), id: \.offset) { _, symbol in
            Keycap(symbol: symbol)
          }
        }
      }
      Spacer()
      if isCapturing {
        Image(systemName: "record.circle")
          .foregroundStyle(.red)
          .accessibilityLabel("Recording")
      }
    }
    .frame(minHeight: 36)
    .padding(.horizontal, 10)
    .background(.quaternary, in: .rect(cornerRadius: 8))
    .background {
      if isCapturing {
        SequenceKeyRecorderRepresentable(
          onRecordStroke: onRecordStroke,
          onDeleteLast: onDeleteLast,
          onFinish: onFinish,
        )
        .frame(width: 0, height: 0)
      }
    }
  }
}

// MARK: - NSViewRepresentable for continuation-key capture.

private struct SequenceKeyRecorderRepresentable: NSViewRepresentable {
  var onRecordStroke: (SequenceKeyStroke) -> Void
  var onDeleteLast: () -> Void
  var onFinish: () -> Void

  func makeNSView(context: Context) -> SequenceKeyRecorderNSView {
    let view = SequenceKeyRecorderNSView()
    view.onRecordStroke = onRecordStroke
    view.onDeleteLast = onDeleteLast
    view.onFinish = onFinish
    return view
  }

  func updateNSView(_ nsView: SequenceKeyRecorderNSView, context: Context) {
    nsView.onRecordStroke = onRecordStroke
    nsView.onDeleteLast = onDeleteLast
    nsView.onFinish = onFinish
  }
}

// MARK: - NSView for continuation-key capture.

// Unlike `HotkeyRecorderNSView` (leader chord), continuation strokes do not
// require a modifier: a bare `w` is a valid stroke. Escape finishes capture
// (it is never recorded as a stroke, which also keeps it out of the reserved
// `<leader>escape=end_key_sequence` cancel slot) and Backspace deletes the last
// stroke (design D5).
final class SequenceKeyRecorderNSView: NSView {
  var onRecordStroke: ((SequenceKeyStroke) -> Void)?
  var onDeleteLast: (() -> Void)?
  var onFinish: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  // Intercept key equivalents so menu shortcuts and the sheet's default button
  // can't fire (or swallow keys) while recording.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    let keyCode = event.keyCode

    if keyCode == UInt16(kVK_Escape) {
      onFinish?()
      return
    }

    if keyCode == UInt16(kVK_Delete) {
      onDeleteLast?()
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers: AppShortcutOverride.ModifierFlags = []
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.shift) { modifiers.insert(.shift) }

    // Store no-modifier strokes as `nil` so the model's optional reads cleanly;
    // `modifiers ?? []` treats them identically.
    let stroke = SequenceKeyStroke(keyCode: keyCode, modifiers: modifiers.isEmpty ? nil : modifiers)
    onRecordStroke?(stroke)
  }
}
