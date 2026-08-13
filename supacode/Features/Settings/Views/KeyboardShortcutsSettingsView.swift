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

  @State private var searchText = ""
  @State private var showRestoreConfirmation = false
  @State private var expandedGroups: Set<String> = Set(Self.visibleGroups.map(\.id))

  // Non-customizable shortcuts are hardcoded chords; they get no row at all.
  private static let visibleGroups: [AppShortcutGroup] = AppShortcuts.groups.compactMap { group in
    let shortcuts = group.shortcuts.filter(\.isCustomizable)
    guard !shortcuts.isEmpty else { return nil }
    return AppShortcutGroup(category: group.category, shortcuts: shortcuts)
  }

  private var filteredGroups: [AppShortcutGroup] {
    guard !searchText.isEmpty else { return Self.visibleGroups }
    let query = searchText.lowercased()
    return Self.visibleGroups.compactMap { group in
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

  // No terminal-conflict pass here: every effective shortcut's chord is
  // unbound inside Ghostty via the app's keybind config lines, so a terminal
  // "conflict" is resolved in the app's favor by construction. The recorder
  // still flags terminal chords at record time.
  private var warningsByID: [AppShortcutID: String] {
    AppShortcuts.conflictWarnings(from: store.shortcutOverrides)
  }

  var body: some View {
    let warnings = warningsByID
    Table(of: ShortcutTableItem.self) {
      TableColumn("Name") { item in
        NameCell(item: item, overrides: store.shortcutOverrides)
      }
      TableColumn("Hotkey") { item in
        HotkeyCell(item: item, store: store, warning: warnings)
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
    .navigationTitle("Shortcuts")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showRestoreConfirmation = true
        } label: {
          Image(systemName: "arrow.counterclockwise")
            .accessibilityLabel("Restore Defaults")
        }
        .help("Restore all shortcuts to their default values.")
        .disabled(!hasAnyOverrides)
        .confirmationDialog(
          "Restore all keyboard shortcuts to their defaults?",
          isPresented: $showRestoreConfirmation,
          titleVisibility: .visible
        ) {
          Button("Restore Defaults", role: .destructive) {
            store.send(.resetAllShortcuts)
          }
        }
      }
    }
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
        // No terminal check: the app unbinds every recorded chord inside
        // Ghostty, so a terminal binding is claimable, not a conflict.
        conflictChecker: { proposed in
          let proposedDisplay = proposed.displayString
          // The hardcoded close chord has no row of its own to explain a
          // bare "System" refusal.
          guard proposedDisplay != AppShortcuts.closeTab.display else {
            return AppShortcuts.closeTab.displayName
          }
          // Check system-reserved shortcuts.
          guard !AppShortcutOverride.allReservedDisplayStrings().contains(proposedDisplay) else {
            return "System"
          }
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
            for shortcut in group.shortcuts where shortcut.isCustomizable {
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
    // Non-customizable shortcuts are always enabled and never counted.
    let customizable = group.shortcuts.filter(\.isCustomizable)
    guard !customizable.isEmpty else { return .checked }
    let enabledCount = customizable.filter { overrides[$0.id]?.isEnabled ?? $0.isEnabledByDefault }.count
    if enabledCount == customizable.count { return .checked }
    if enabledCount == 0 { return .unchecked }
    return .mixed
  }
}
