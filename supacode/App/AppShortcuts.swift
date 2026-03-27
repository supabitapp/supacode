import Sharing
import SwiftUI

// MARK: - Shortcut identity.

// Compile-time checkable shortcut identifier.
nonisolated enum AppShortcutID: Codable, Hashable, Sendable, CodingKeyRepresentable {
  case commandPalette, openSettings, checkForUpdates
  case toggleLeftSidebar
  case newWorktree, refreshWorktrees, archivedWorktrees, archiveWorktree
  case deleteWorktree, confirmWorktreeAction
  case selectNextWorktree, selectPreviousWorktree
  case selectWorktree(Int)
  case openFinder, openRepository, openPullRequest, copyPath
  case runScript, stopRunScript

  // Stable string key for JSON dictionary persistence.
  var codingKey: CodingKey {
    StringCodingKey(stableKey)
  }

  init?<T: CodingKey>(codingKey: T) {
    self.init(stableKey: codingKey.stringValue)
  }

  private struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  private var stableKey: String {
    switch self {
    case .commandPalette: "commandPalette"
    case .openSettings: "openSettings"
    case .checkForUpdates: "checkForUpdates"
    case .toggleLeftSidebar: "toggleLeftSidebar"
    case .newWorktree: "newWorktree"
    case .refreshWorktrees: "refreshWorktrees"
    case .archivedWorktrees: "archivedWorktrees"
    case .archiveWorktree: "archiveWorktree"
    case .deleteWorktree: "deleteWorktree"
    case .confirmWorktreeAction: "confirmWorktreeAction"
    case .selectNextWorktree: "selectNextWorktree"
    case .selectPreviousWorktree: "selectPreviousWorktree"
    case .selectWorktree(let index): "selectWorktree\(index)"
    case .openFinder: "openFinder"
    case .openRepository: "openRepository"
    case .openPullRequest: "openPullRequest"
    case .copyPath: "copyPath"
    case .runScript: "runScript"
    case .stopRunScript: "stopRunScript"
    }
  }

  private static let stableKeyMap: [String: AppShortcutID] = [
    "commandPalette": .commandPalette,
    "openSettings": .openSettings,
    "checkForUpdates": .checkForUpdates,
    "toggleLeftSidebar": .toggleLeftSidebar,
    "newWorktree": .newWorktree,
    "refreshWorktrees": .refreshWorktrees,
    "archivedWorktrees": .archivedWorktrees,
    "archiveWorktree": .archiveWorktree,
    "deleteWorktree": .deleteWorktree,
    "confirmWorktreeAction": .confirmWorktreeAction,
    "selectNextWorktree": .selectNextWorktree,
    "selectPreviousWorktree": .selectPreviousWorktree,
    "openFinder": .openFinder,
    "openRepository": .openRepository,
    "openPullRequest": .openPullRequest,
    "copyPath": .copyPath,
    "runScript": .runScript,
    "stopRunScript": .stopRunScript,
  ]

  private init?(stableKey: String) {
    if stableKey.hasPrefix("selectWorktree"),
      let index = Int(String(stableKey.dropFirst("selectWorktree".count)))
    {
      self = .selectWorktree(index)
      return
    }
    guard let id = Self.stableKeyMap[stableKey] else { return nil }
    self = id
  }

  // Human-readable name for display in settings and tooltips.
  var displayName: String {
    switch self {
    case .commandPalette: "Command Palette"
    case .openSettings: "Open Settings"
    case .checkForUpdates: "Check For Updates"
    case .toggleLeftSidebar: "Toggle Left Sidebar"
    case .newWorktree: "New Worktree"
    case .refreshWorktrees: "Refresh Worktrees"
    case .archivedWorktrees: "Archived Worktrees"
    case .archiveWorktree: "Archive Worktree"
    case .deleteWorktree: "Delete Worktree"
    case .confirmWorktreeAction: "Confirm Worktree Action"
    case .selectNextWorktree: "Select Next Worktree"
    case .selectPreviousWorktree: "Select Previous Worktree"
    case .selectWorktree(let index): "Select Worktree \(index == 0 ? 10 : index)"
    case .openFinder: "Open Finder"
    case .openRepository: "Open Repository"
    case .openPullRequest: "Open Pull Request"
    case .copyPath: "Copy Path"
    case .runScript: "Run Script"
    case .stopRunScript: "Stop Run Script"
    }
  }
}

// MARK: - Shortcut definition.

struct AppShortcut: Identifiable {
  let id: AppShortcutID
  let keyEquivalent: KeyEquivalent
  let modifiers: EventModifiers
  private let keyCode: UInt16?
  private let ghosttyKeyName: String

  init(id: AppShortcutID, key: Character, modifiers: EventModifiers) {
    self.id = id
    self.modifiers = modifiers
    // Resolve the physical key code from the US QWERTY character to enable
    // layout-aware display and Ghostty keybind generation.
    let code = AppShortcutOverride.keyCode(for: key)
    self.keyCode = code
    if let code, let layoutChar = AppShortcutOverride.layoutCharacter(for: code) {
      self.keyEquivalent = KeyEquivalent(Character(layoutChar))
      self.ghosttyKeyName = layoutChar.lowercased()
    } else {
      self.keyEquivalent = KeyEquivalent(key)
      self.ghosttyKeyName = String(key).lowercased()
    }
  }

  init(id: AppShortcutID, keyEquivalent: KeyEquivalent, ghosttyKeyName: String, modifiers: EventModifiers) {
    self.id = id
    self.keyEquivalent = keyEquivalent
    self.modifiers = modifiers
    self.keyCode = nil
    self.ghosttyKeyName = ghosttyKeyName
  }

  var displayName: String { id.displayName }

  var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [ghosttyKeyName]
    return parts.joined(separator: "+")
  }

  var ghosttyUnbindArgument: String {
    "--keybind=\(ghosttyKeybind)=unbind"
  }

  // Layout-aware display string.
  var display: String {
    displaySymbols.joined()
  }

  var displaySymbols: [String] {
    displayModifierParts + [keyDisplay]
  }

  private var keyDisplay: String {
    if let keyCode, let layoutChar = AppShortcutOverride.layoutCharacter(for: keyCode) {
      layoutChar.uppercased()
    } else {
      keyEquivalent.display
    }
  }

  // Resolves the effective shortcut considering user overrides.
  // Returns `nil` when the user has disabled this shortcut.
  func effective(from overrides: [AppShortcutID: AppShortcutOverride]) -> AppShortcut? {
    guard let override = overrides[id] else { return self }
    guard override.isEnabled else { return nil }
    return AppShortcut(id: id, override: override)
  }

  private init(id: AppShortcutID, override: AppShortcutOverride) {
    self.id = id
    self.keyEquivalent = override.keyEquivalent
    self.modifiers = override.eventModifiers
    self.keyCode = override.keyCode
    self.ghosttyKeyName = AppShortcutOverride.resolvedGhosttyKeyName(for: override.keyCode)
  }

  private var ghosttyModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("super") }
    return parts
  }

  private var displayModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    return parts
  }
}

// MARK: - Category and grouping.

enum AppShortcutCategory: String, CaseIterable, Sendable {
  case general
  case sidebar
  case worktrees
  case worktreeSelection
  case actions

  var displayName: String {
    switch self {
    case .general: "General"
    case .sidebar: "Sidebar"
    case .worktrees: "Worktrees"
    case .worktreeSelection: "Worktree Selection"
    case .actions: "Actions"
    }
  }
}

struct AppShortcutGroup: Identifiable {
  let category: AppShortcutCategory
  let shortcuts: [AppShortcut]

  var id: String { category.rawValue }
}

// MARK: - Registry.

enum AppShortcuts {
  private struct TabSelectionBinding {
    let unicode: String
    let physical: String
    let tabIndex: Int
  }

  private static let tabSelectionBindings: [TabSelectionBinding] = [
    TabSelectionBinding(unicode: "1", physical: "digit_1", tabIndex: 1),
    TabSelectionBinding(unicode: "2", physical: "digit_2", tabIndex: 2),
    TabSelectionBinding(unicode: "3", physical: "digit_3", tabIndex: 3),
    TabSelectionBinding(unicode: "4", physical: "digit_4", tabIndex: 4),
    TabSelectionBinding(unicode: "5", physical: "digit_5", tabIndex: 5),
    TabSelectionBinding(unicode: "6", physical: "digit_6", tabIndex: 6),
    TabSelectionBinding(unicode: "7", physical: "digit_7", tabIndex: 7),
    TabSelectionBinding(unicode: "8", physical: "digit_8", tabIndex: 8),
    TabSelectionBinding(unicode: "9", physical: "digit_9", tabIndex: 9),
    TabSelectionBinding(unicode: "0", physical: "digit_0", tabIndex: 10),
  ]

  // MARK: - Shortcut definitions.

  static let commandPalette = AppShortcut(id: .commandPalette, key: "p", modifiers: .command)
  static let openSettings = AppShortcut(id: .openSettings, key: ",", modifiers: .command)
  static let checkForUpdates = AppShortcut(id: .checkForUpdates, key: "u", modifiers: .command)

  static let toggleLeftSidebar = AppShortcut(id: .toggleLeftSidebar, key: "[", modifiers: .command)

  static let newWorktree = AppShortcut(id: .newWorktree, key: "n", modifiers: .command)
  static let refreshWorktrees = AppShortcut(id: .refreshWorktrees, key: "r", modifiers: [.command, .shift])
  static let archivedWorktrees = AppShortcut(id: .archivedWorktrees, key: "a", modifiers: [.command, .control])
  static let archiveWorktree = AppShortcut(
    id: .archiveWorktree,
    keyEquivalent: .delete, ghosttyKeyName: "backspace", modifiers: .command
  )
  static let deleteWorktree = AppShortcut(
    id: .deleteWorktree,
    keyEquivalent: .delete, ghosttyKeyName: "backspace", modifiers: [.command, .shift]
  )
  static let confirmWorktreeAction = AppShortcut(
    id: .confirmWorktreeAction,
    keyEquivalent: .return, ghosttyKeyName: "return", modifiers: .command
  )
  static let selectNextWorktree = AppShortcut(
    id: .selectNextWorktree,
    keyEquivalent: .downArrow, ghosttyKeyName: "arrow_down", modifiers: [.command, .control]
  )
  static let selectPreviousWorktree = AppShortcut(
    id: .selectPreviousWorktree,
    keyEquivalent: .upArrow, ghosttyKeyName: "arrow_up", modifiers: [.command, .control]
  )

  static let selectWorktree1 = AppShortcut(id: .selectWorktree(1), key: "1", modifiers: [.control])
  static let selectWorktree2 = AppShortcut(id: .selectWorktree(2), key: "2", modifiers: [.control])
  static let selectWorktree3 = AppShortcut(id: .selectWorktree(3), key: "3", modifiers: [.control])
  static let selectWorktree4 = AppShortcut(id: .selectWorktree(4), key: "4", modifiers: [.control])
  static let selectWorktree5 = AppShortcut(id: .selectWorktree(5), key: "5", modifiers: [.control])
  static let selectWorktree6 = AppShortcut(id: .selectWorktree(6), key: "6", modifiers: [.control])
  static let selectWorktree7 = AppShortcut(id: .selectWorktree(7), key: "7", modifiers: [.control])
  static let selectWorktree8 = AppShortcut(id: .selectWorktree(8), key: "8", modifiers: [.control])
  static let selectWorktree9 = AppShortcut(id: .selectWorktree(9), key: "9", modifiers: [.control])
  static let selectWorktree0 = AppShortcut(id: .selectWorktree(0), key: "0", modifiers: [.control])

  static let openFinder = AppShortcut(id: .openFinder, key: "o", modifiers: .command)
  static let openRepository = AppShortcut(id: .openRepository, key: "o", modifiers: [.command, .shift])
  static let openPullRequest = AppShortcut(id: .openPullRequest, key: "g", modifiers: [.command, .control])
  static let copyPath = AppShortcut(id: .copyPath, key: "c", modifiers: [.command, .shift])
  static let runScript = AppShortcut(id: .runScript, key: "r", modifiers: .command)
  static let stopRunScript = AppShortcut(id: .stopRunScript, key: ".", modifiers: .command)

  static let worktreeSelection: [AppShortcut] = [
    selectWorktree1, selectWorktree2, selectWorktree3, selectWorktree4, selectWorktree5,
    selectWorktree6, selectWorktree7, selectWorktree8, selectWorktree9, selectWorktree0,
  ]

  // MARK: - Groups.

  static let groups: [AppShortcutGroup] = [
    AppShortcutGroup(category: .general, shortcuts: [commandPalette, openSettings, checkForUpdates]),
    AppShortcutGroup(category: .sidebar, shortcuts: [toggleLeftSidebar]),
    AppShortcutGroup(
      category: .worktrees,
      shortcuts: [
        newWorktree, refreshWorktrees, archivedWorktrees, archiveWorktree,
        deleteWorktree, confirmWorktreeAction, selectNextWorktree, selectPreviousWorktree,
      ]
    ),
    AppShortcutGroup(category: .worktreeSelection, shortcuts: worktreeSelection),
    AppShortcutGroup(
      category: .actions,
      shortcuts: [openFinder, openRepository, openPullRequest, copyPath, runScript, stopRunScript]
    ),
  ]

  // MARK: - All shortcuts.

  static let all: [AppShortcut] = groups.flatMap(\.shortcuts)

  // MARK: - Tab selection Ghostty bindings.

  static let tabSelectionGhosttyKeybindArguments: [String] = tabSelectionBindings.flatMap { binding in
    [
      "--keybind=ctrl+\(binding.unicode)=goto_tab:\(binding.tabIndex)",
      "--keybind=ctrl+\(binding.physical)=goto_tab:\(binding.tabIndex)",
    ]
  }

  // MARK: - Ghostty CLI arguments.

  static var ghosttyCLIKeybindArguments: [String] {
    ghosttyCLIKeybindArguments(from: [:])
  }

  static func ghosttyCLIKeybindArguments(from overrides: [AppShortcutID: AppShortcutOverride]) -> [String] {
    let effectiveShortcuts = all.compactMap { $0.effective(from: overrides) }
    return effectiveShortcuts.map(\.ghosttyUnbindArgument) + tabSelectionGhosttyKeybindArguments
  }

  // MARK: - Conflict detection.

  // Computes conflict warnings for all shortcuts given the current overrides.
  static func conflictWarnings(
    from overrides: [AppShortcutID: AppShortcutOverride]
  ) -> [AppShortcutID: String] {
    let reserved = AppShortcutOverride.allReservedDisplayStrings()
    var displayToIDs: [String: [AppShortcutID]] = [:]
    var warnings: [AppShortcutID: String] = [:]

    for shortcut in all {
      guard let effective = shortcut.effective(from: overrides) else { continue }
      let display = effective.display
      displayToIDs[display, default: []].append(shortcut.id)

      if reserved.contains(display) {
        warnings[shortcut.id] = "\(display) is reserved by the system."
      }
    }

    for (_, ids) in displayToIDs where ids.count > 1 {
      for id in ids {
        let others = ids.filter { $0 != id }
        let otherLabels = others.compactMap { otherID in
          all.first { $0.id == otherID }?.displayName
        }
        let existing = warnings[id].map { $0 + " " } ?? ""
        warnings[id] = existing + "Conflicts with \(otherLabels.joined(separator: ", "))."
      }
    }

    return warnings
  }
}

// MARK: - View modifier.

extension View {
  @ViewBuilder
  func appKeyboardShortcut(_ shortcut: AppShortcut?) -> some View {
    if let shortcut {
      self.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
    } else {
      self
    }
  }
}
