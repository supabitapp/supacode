import Carbon.HIToolbox
import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

// Row model for the outline table.
struct ShortcutTableItem: Identifiable {
  enum Kind {
    case group(AppShortcutCategory)
    case shortcut(AppShortcut)
  }

  let id: String
  let kind: Kind
  let children: [ShortcutTableItem]?
}

struct KeyboardShortcutsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts

  @State private var searchText = ""
  @State private var showRestoreConfirmation = false
  @State private var expandedGroups: Set<String> = Set(AppShortcuts.groups.map(\.id))

  private var filteredGroups: [AppShortcutGroup] {
    guard !searchText.isEmpty else { return AppShortcuts.groups }
    let query = searchText.lowercased()
    return AppShortcuts.groups.compactMap { group in
      let filtered = group.shortcuts.filter { shortcut in
        shortcut.displayName.lowercased().contains(query)
          || shortcut.display.lowercased().contains(query)
      }
      guard !filtered.isEmpty else { return nil }
      return AppShortcutGroup(category: group.category, shortcuts: filtered)
    }
  }

  private var tableItems: [ShortcutTableItem] {
    filteredGroups.map { group in
      ShortcutTableItem(
        id: group.id,
        kind: .group(group.category),
        children: group.shortcuts.map { shortcut in
          ShortcutTableItem(
            id: shortcut.displayName,
            kind: .shortcut(shortcut),
            children: nil
          )
        }
      )
    }
  }

  private var hasAnyOverrides: Bool {
    !store.shortcutOverrides.isEmpty
  }

  // Restore-defaults is also the path that clears a configured leader, so it
  // stays enabled whenever either single chords or a leader are customized.
  private var canRestoreDefaults: Bool {
    hasAnyOverrides || store.leaderKey != nil
  }

  private var warningsByID: [AppShortcutID: String] {
    var warnings = AppShortcuts.conflictWarnings(from: store.shortcutOverrides)
    let terminalDisplays = ghosttyShortcuts.reservedDisplayStrings
    guard !terminalDisplays.isEmpty else { return warnings }
    for shortcut in AppShortcuts.all {
      guard let effective = shortcut.effective(from: store.shortcutOverrides) else { continue }
      guard terminalDisplays.contains(effective.display) else { continue }
      let existing = warnings[shortcut.id].map { $0 + " " } ?? ""
      warnings[shortcut.id] = existing + "Conflicts with Terminal."
    }
    return warnings
  }

  var body: some View {
    let warnings = warningsByID
    let terminalDisplays = ghosttyShortcuts.reservedDisplayStrings
    VStack(spacing: 0) {
      LeaderKeyConfigurationView(store: store, terminalReservedDisplays: terminalDisplays)
        .padding()
      Divider()
      shortcutsTable(warnings: warnings, terminalDisplays: terminalDisplays)
    }
    .navigationTitle("Shortcuts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showRestoreConfirmation = true
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .accessibilityLabel("Restore Defaults")
        }
        .help("Restore all shortcuts, including the leader key and its sequences, to their defaults.")
        .disabled(!canRestoreDefaults)
        .confirmationDialog(
          "Restore all keyboard shortcuts to their defaults?",
          isPresented: $showRestoreConfirmation,
          titleVisibility: .visible,
        ) {
          Button("Restore Defaults", role: .destructive) {
            store.send(.resetAllShortcuts)
            store.send(.resetLeaderKey)
          }
        } message: {
          Text("This clears every custom shortcut and removes the leader key and all of its sequences.")
        }
      }
    }
  }

  private func shortcutsTable(
    warnings: [AppShortcutID: String],
    terminalDisplays: Set<String>,
  ) -> some View {
    Table(of: ShortcutTableItem.self) {
      TableColumn("Name") { item in
        NameCell(item: item, overrides: store.shortcutOverrides)
      }
      TableColumn("Hotkey") { item in
        HotkeyCell(item: item, store: store, warning: warnings, terminalReservedDisplays: terminalDisplays)
      }
      .width(min: 90, ideal: 120, max: 200)
      TableColumn("Enabled") { item in
        EnabledCell(item: item, store: store)
      }
      .width(min: 60, max: 90)
    } rows: {
      ForEach(tableItems) { group in
        DisclosureTableRow(
          group,
          isExpanded: Binding(
            get: { expandedGroups.contains(group.id) },
            set: { expanded in
              if expanded {
                expandedGroups.insert(group.id)
              } else {
                expandedGroups.remove(group.id)
              }
            }
          )
        ) {
          if let children = group.children {
            ForEach(children) { child in
              TableRow(child)
            }
          }
        }
      }
    }
    .alternatingRowBackgrounds()
    .padding(.leading, -6)
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search...")
  }
}

// MARK: - Leader key configuration.

// The leader-key configuration surface: a single chord row (set / clear the
// leader) plus a list of multi-key sequences (leader + ordered strokes -> a
// host-routable Ghostty built-in). Conflict warnings from the pure
// `LeaderKeyConflictValidator` are surfaced inline and are non-blocking. Sits
// above the per-action single-chord table so the two binding styles stay visually
// distinct. Keybinds apply at launch, mirroring single-chord overrides, so the
// row notes "applies after relaunch".
//
// which-key overlay seam: a discoverability popup that shows the available next
// keys mid-sequence is intentionally deferred (design D7). A future overlay can
// observe `GhosttySurfaceState.keySequenceActive` / `keyTableName` (already wired
// by `GhosttySurfaceBridge`) without re-plumbing this view.
private struct LeaderKeyConfigurationView: View {
  let store: StoreOf<SettingsFeature>
  let terminalReservedDisplays: Set<String>

  @State private var isRecordingLeader = false
  @State private var editTarget: SequenceEditTarget?

  // Identifies the editor sheet. A new sequence has no underlying `existing`.
  private struct SequenceEditTarget: Identifiable {
    let id: UUID
    let existing: LeaderKeySequence?
  }

  // Default leader suggestion (D1): ⌘K is free in-app and is a modifier chord
  // (REQ-001). Pre-filling the recorder makes the leader discoverable without
  // seeding it, so nothing is intercepted until the user sets a leader.
  private static let suggestedLeader = AppShortcutOverride(
    keyCode: UInt16(kVK_ANSI_K),
    modifiers: .command,
  )

  // Reserved chords for both the leader-conflict check and the pre-commit
  // recorder check: system/AppKit reserved plus the terminal's own bindings,
  // so a leader that the terminal would swallow is flagged.
  private var reservedDisplayStrings: Set<String> {
    AppShortcutOverride.allReservedDisplayStrings().union(terminalReservedDisplays)
  }

  private var report: LeaderKeyConflictReport {
    LeaderKeyConflictValidator.validate(
      config: store.leaderKey,
      shortcutOverrides: store.shortcutOverrides,
      reservedDisplayStrings: reservedDisplayStrings,
    )
  }

  var body: some View {
    let report = report
    VStack(alignment: .leading, spacing: 12) {
      header
      leaderRow(report: report)
      if store.leaderKey != nil {
        Divider()
        sequencesSection(report: report)
      }
    }
    .sheet(item: $editTarget) { target in
      LeaderSequenceEditorSheet(
        existing: target.existing,
        onSave: { sequence in
          store.send(.updateLeaderSequence(sequence))
          editTarget = nil
        },
        onCancel: { editTarget = nil },
      )
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Leader Key")
        .font(.headline)
      Text("Press the leader chord, then a sequence of keys, to run an action. Applies after relaunch.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func leaderRow(report: LeaderKeyConflictReport) -> some View {
    HStack(spacing: 8) {
      if let leaderKey = store.leaderKey {
        HStack(spacing: 3) {
          ForEach(Array(leaderKey.leaderChord.displaySymbols.enumerated()), id: \.offset) { _, symbol in
            Keycap(symbol: symbol)
          }
        }
        Button("Change…") { isRecordingLeader = true }
          .help("Record a new leader chord. Existing sequences are kept.")
        Button(role: .destructive) {
          store.send(.resetLeaderKey)
        } label: {
          Text("Clear")
        }
        .help("Remove the leader key and all of its sequences.")
      } else {
        Text("No leader key set")
          .foregroundStyle(.secondary)
        Button("Use \(Self.suggestedLeader.displayString)") {
          store.send(.updateLeaderChord(Self.suggestedLeader))
        }
        .help("Use the suggested \(Self.suggestedLeader.displayString) leader chord.")
        Button("Set Leader…") { isRecordingLeader = true }
          .help("Record a custom leader chord. A modifier (such as ⌘) is required.")
      }
      Spacer()
    }
    .popover(isPresented: $isRecordingLeader) {
      HotkeyRecorderPopover(
        onRecorded: { override in store.send(.updateLeaderChord(override)) },
        onCancelled: { isRecordingLeader = false },
        conflictChecker: leaderConflictChecker,
      )
    }
    if !report.leaderConflicts.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(report.leaderConflicts.enumerated()), id: \.offset) { _, conflict in
          LeaderConflictLabel(message: conflict.message)
        }
      }
    }
  }

  @ViewBuilder
  private func sequencesSection(report: LeaderKeyConflictReport) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Sequences")
          .font(.subheadline.weight(.medium))
        Spacer()
        Button {
          editTarget = SequenceEditTarget(id: UUID(), existing: nil)
        } label: {
          Label("Add Sequence", systemImage: "plus")
        }
        .help("Add a new leader sequence.")
      }
      if let sequences = store.leaderKey?.sequences, !sequences.isEmpty {
        ForEach(sequences) { sequence in
          LeaderSequenceRow(
            leaderChord: store.leaderKey?.leaderChord,
            sequence: sequence,
            conflicts: report.conflicts(for: sequence.id),
            onEdit: { editTarget = SequenceEditTarget(id: sequence.id, existing: sequence) },
            onRemove: { store.send(.removeLeaderSequence(sequence.id)) },
          )
        }
      } else {
        Text("No sequences yet. Add one to bind a leader sequence to an action.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // Pre-commit conflict surface for the leader recorder popover, mirroring the
  // single-chord recorder: returns the colliding owner's name, or `nil`.
  private func leaderConflictChecker(_ proposed: AppShortcutOverride) -> String? {
    let proposedDisplay = proposed.displayString
    guard !AppShortcutOverride.allReservedDisplayStrings().contains(proposedDisplay) else {
      return "System"
    }
    guard !terminalReservedDisplays.contains(proposedDisplay) else { return "Terminal" }
    for shortcut in AppShortcuts.all {
      guard let effective = shortcut.effective(from: store.shortcutOverrides) else { continue }
      guard effective.display == proposedDisplay else { continue }
      return shortcut.displayName
    }
    return nil
  }
}

// MARK: - Leader sequence row.

private struct LeaderSequenceRow: View {
  let leaderChord: AppShortcutOverride?
  let sequence: LeaderKeySequence
  let conflicts: [LeaderKeyConflict]
  let onEdit: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        HStack(spacing: 3) {
          if let leaderChord {
            ForEach(Array(leaderChord.displaySymbols.enumerated()), id: \.offset) { _, symbol in
              Keycap(symbol: symbol)
            }
          }
          ForEach(Array(sequence.keyStrokes.enumerated()), id: \.offset) { _, stroke in
            ForEach(Array(stroke.displaySymbols.enumerated()), id: \.offset) { _, symbol in
              Keycap(symbol: symbol)
            }
          }
        }
        Image(systemName: "arrow.right")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(sequence.target.ghosttyAction?.displayName ?? "Unknown action")
          .foregroundStyle(.primary)
        Spacer()
        Button {
          onEdit()
        } label: {
          Image(systemName: "pencil")
            .accessibilityLabel("Edit Sequence")
        }
        .buttonStyle(.borderless)
        .help("Edit this leader sequence.")
        Button {
          onRemove()
        } label: {
          Image(systemName: "trash")
            .accessibilityLabel("Remove Sequence")
        }
        .buttonStyle(.borderless)
        .help("Remove this leader sequence.")
      }
      ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
        LeaderConflictLabel(message: conflict.message)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Conflict label.

// Inline, non-blocking conflict warning, styled like the single-chord table's
// warning affordance (a yellow triangle) for consistency.
private struct LeaderConflictLabel: View {
  let message: String

  var body: some View {
    Label {
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption2)
        .foregroundStyle(.yellow)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Warning: \(message)")
  }
}

// MARK: - Cell views.

private struct NameCell: View {
  let item: ShortcutTableItem
  let overrides: [AppShortcutID: AppShortcutOverride]

  var body: some View {
    switch item.kind {
    case .group(let category):
      Text(category.displayName)
        .padding(.vertical, 4)
    case .shortcut(let shortcut):
      Text(shortcut.displayName)
        .foregroundStyle(overrides[shortcut.id]?.isEnabled ?? shortcut.isEnabledByDefault ? .primary : .secondary)
        .padding(.vertical, 4)
    }
  }
}

private struct HotkeyCell: View {
  let item: ShortcutTableItem
  let store: StoreOf<SettingsFeature>
  let warning: [AppShortcutID: String]
  let terminalReservedDisplays: Set<String>

  var body: some View {
    switch item.kind {
    case .group:
      EmptyView()
    case .shortcut(let shortcut):
      HotkeyCellView(
        shortcut: shortcut,
        override: store.shortcutOverrides[shortcut.id],
        isEnabled: store.shortcutOverrides[shortcut.id]?.isEnabled ?? shortcut.isEnabledByDefault,
        warning: warning[shortcut.id],
        onRecorded: { newOverride in
          store.send(.updateShortcut(id: shortcut.id, override: newOverride))
        },
        onReset: {
          store.send(.updateShortcut(id: shortcut.id, override: nil))
        },
        conflictChecker: { proposed in
          let proposedDisplay = proposed.displayString
          // Check system-reserved shortcuts.
          guard !AppShortcutOverride.allReservedDisplayStrings().contains(proposedDisplay) else {
            return "System"
          }
          // Check terminal shortcuts.
          guard !terminalReservedDisplays.contains(proposedDisplay) else { return "Terminal" }
          // Check other app shortcuts.
          let overrides = store.shortcutOverrides
          for other in AppShortcuts.all where other.id != shortcut.id {
            guard let effective = other.effective(from: overrides) else { continue }
            guard effective.display == proposedDisplay else { continue }
            return other.displayName
          }
          return nil
        }
      )
    }
  }
}

private struct EnabledCell: View {
  let item: ShortcutTableItem
  let store: StoreOf<SettingsFeature>

  var body: some View {
    switch item.kind {
    case .group(let category):
      if let group = AppShortcuts.groups.first(where: { $0.category == category }) {
        MixedStateCheckbox(
          state: groupCheckboxState(for: group),
          onToggle: { enabled in
            for shortcut in group.shortcuts {
              store.send(.toggleShortcutEnabled(id: shortcut.id, enabled: enabled))
            }
          }
        ).frame(maxWidth: .infinity, alignment: .center)
      }
    case .shortcut(let shortcut):
      Toggle(
        "",
        isOn: Binding(
          get: { store.shortcutOverrides[shortcut.id]?.isEnabled ?? shortcut.isEnabledByDefault },
          set: { store.send(.toggleShortcutEnabled(id: shortcut.id, enabled: $0)) }
        )
      )
      .frame(maxWidth: .infinity, alignment: .center)
      .toggleStyle(.checkbox)
      .labelsHidden()
    }
  }

  private func groupCheckboxState(for group: AppShortcutGroup) -> CheckboxState {
    let overrides = store.shortcutOverrides
    let enabledCount = group.shortcuts.filter { overrides[$0.id]?.isEnabled ?? $0.isEnabledByDefault }.count
    if enabledCount == group.shortcuts.count { return .checked }
    if enabledCount == 0 { return .unchecked }
    return .mixed
  }
}
