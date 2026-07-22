import AppKit
import Sharing
import SwiftUI

// MARK: - Shortcut identity.

// Compile-time checkable shortcut identifier.
public nonisolated enum AppShortcutID: Codable, Hashable, Sendable, CodingKeyRepresentable {
  case commandPalette, worktreeSwitcher, openSettings, checkForUpdates, showMainWindow
  case toggleLeftSidebar, revealInSidebar
  case expandAllSidebarGroups, collapseAllSidebarGroups
  case newWorktree, refreshWorktrees, archivedWorktrees, archiveWorktree
  case deleteWorktree, confirmWorktreeAction
  case selectNextWorktree, selectPreviousWorktree
  case worktreeHistoryBack, worktreeHistoryForward
  case selectWorktree(Int)
  case selectTab(Int)
  case openWorktree, revealInFinder, openRepository, addRemoteRepository, cloneRepository, openPullRequest, copyPath
  case runScript, stopRunScript
  case jumpToLatestUnread
  case togglePullRequestInspector, toggleNotificationsInspector

  // Stable string key for JSON dictionary persistence.
  public var codingKey: CodingKey {
    StringCodingKey(stableKey)
  }

  public init?<T: CodingKey>(codingKey: T) {
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
    case .worktreeSwitcher: "worktreeSwitcher"
    case .openSettings: "openSettings"
    case .checkForUpdates: "checkForUpdates"
    case .showMainWindow: "showMainWindow"
    case .toggleLeftSidebar: "toggleLeftSidebar"
    case .revealInSidebar: "revealInSidebar"
    case .expandAllSidebarGroups: "expandAllSidebarGroups"
    case .collapseAllSidebarGroups: "collapseAllSidebarGroups"
    case .newWorktree: "newWorktree"
    case .refreshWorktrees: "refreshWorktrees"
    case .archivedWorktrees: "archivedWorktrees"
    case .archiveWorktree: "archiveWorktree"
    case .deleteWorktree: "deleteWorktree"
    case .confirmWorktreeAction: "confirmWorktreeAction"
    case .selectNextWorktree: "selectNextWorktree"
    case .selectPreviousWorktree: "selectPreviousWorktree"
    case .worktreeHistoryBack: "worktreeHistoryBack"
    case .worktreeHistoryForward: "worktreeHistoryForward"
    case .selectWorktree(let index): "selectWorktree\(index)"
    case .selectTab(let index): "selectTab\(index)"
    case .openWorktree: "openWorktree"
    case .revealInFinder: "revealInFinder"
    case .openRepository: "openRepository"
    case .addRemoteRepository: "addRemoteRepository"
    case .cloneRepository: "cloneRepository"
    case .openPullRequest: "openPullRequest"
    case .copyPath: "copyPath"
    case .runScript: "runScript"
    case .stopRunScript: "stopRunScript"
    case .jumpToLatestUnread: "jumpToLatestUnread"
    case .togglePullRequestInspector: "togglePullRequestInspector"
    case .toggleNotificationsInspector: "toggleNotificationsInspector"
    }
  }

  private static let stableKeyMap: [String: AppShortcutID] = [
    "commandPalette": .commandPalette,
    "worktreeSwitcher": .worktreeSwitcher,
    "openSettings": .openSettings,
    "checkForUpdates": .checkForUpdates,
    "showMainWindow": .showMainWindow,
    "toggleLeftSidebar": .toggleLeftSidebar,
    "revealInSidebar": .revealInSidebar,
    "expandAllSidebarGroups": .expandAllSidebarGroups,
    "collapseAllSidebarGroups": .collapseAllSidebarGroups,
    "newWorktree": .newWorktree,
    "refreshWorktrees": .refreshWorktrees,
    "archivedWorktrees": .archivedWorktrees,
    "archiveWorktree": .archiveWorktree,
    "deleteWorktree": .deleteWorktree,
    "confirmWorktreeAction": .confirmWorktreeAction,
    "selectNextWorktree": .selectNextWorktree,
    "selectPreviousWorktree": .selectPreviousWorktree,
    "worktreeHistoryBack": .worktreeHistoryBack,
    "worktreeHistoryForward": .worktreeHistoryForward,
    "openWorktree": .openWorktree,
    "openFinder": .openWorktree,
    "revealInFinder": .revealInFinder,
    "openRepository": .openRepository,
    "addRemoteRepository": .addRemoteRepository,
    "cloneRepository": .cloneRepository,
    "openPullRequest": .openPullRequest,
    "copyPath": .copyPath,
    "runScript": .runScript,
    "stopRunScript": .stopRunScript,
    "jumpToLatestUnread": .jumpToLatestUnread,
    "togglePullRequestInspector": .togglePullRequestInspector,
    "toggleNotificationsInspector": .toggleNotificationsInspector,
  ]

  private init?(stableKey: String) {
    if stableKey.hasPrefix("selectWorktree"),
      let index = Int(String(stableKey.dropFirst("selectWorktree".count)))
    {
      self = .selectWorktree(index)
      return
    }
    if stableKey.hasPrefix("selectTab"),
      let index = Int(String(stableKey.dropFirst("selectTab".count)))
    {
      self = .selectTab(index)
      return
    }
    guard let id = Self.stableKeyMap[stableKey] else { return nil }
    self = id
  }

  // Human-readable name for display in settings and tooltips.
  public var displayName: String {
    switch self {
    case .commandPalette: "Command Palette"
    case .worktreeSwitcher: "Go to Worktree"
    case .openSettings: "Open Settings"
    case .checkForUpdates: "Check For Updates"
    case .showMainWindow: "Show Main Window"
    case .toggleLeftSidebar: "Toggle Left Sidebar"
    case .revealInSidebar: "Reveal in Sidebar"
    case .expandAllSidebarGroups: "Expand All Sidebar Groups"
    case .collapseAllSidebarGroups: "Collapse All Sidebar Groups"
    case .newWorktree: "New Worktree"
    case .refreshWorktrees: "Refresh Worktrees"
    case .archivedWorktrees: "Archived Worktrees"
    case .archiveWorktree: "Archive Worktree"
    case .deleteWorktree: "Delete Worktree"
    case .confirmWorktreeAction: "Confirm Worktree Action"
    case .selectNextWorktree: "Select Next Worktree"
    case .selectPreviousWorktree: "Select Previous Worktree"
    case .worktreeHistoryBack: "Back in Worktree History"
    case .worktreeHistoryForward: "Forward in Worktree History"
    case .selectWorktree(let index): "Select Worktree \(index == 0 ? 10 : index)"
    case .selectTab(let index): "Select Tab \(index)"
    case .openWorktree: "Open Worktree"
    case .revealInFinder: "Reveal in Finder"
    case .openRepository: "Open Repository or Folder"
    case .addRemoteRepository: "Add Remote Repository or Folder"
    case .cloneRepository: "Clone Repository to Local Folder"
    case .openPullRequest: "Open Pull Request"
    case .copyPath: "Copy Path"
    case .runScript: "Run Script"
    case .stopRunScript: "Stop Run Script"
    case .jumpToLatestUnread: "Jump to Latest Unread"
    case .togglePullRequestInspector: "Toggle Pull Request Inspector"
    case .toggleNotificationsInspector: "Toggle Notifications Inspector"
    }
  }
}

// MARK: - Shortcut definition.

private nonisolated let shortcutLogger = SupaLogger("Shortcuts")

public struct AppShortcut: Identifiable {
  public let id: AppShortcutID
  public let keyEquivalent: KeyEquivalent
  public let modifiers: EventModifiers
  private let keyCode: UInt16?
  // True when the key code came from a rebind, where it is the physical key the user
  // actually pressed. The defaults instead derive theirs from a character, so theirs is
  // only ever as good as the layout that was active when the shortcut was built.
  private let keyCodeIsExplicit: Bool
  private let ghosttyKeyName: String
  // Whether the binding is active with no user override; `false` ships the
  // shortcut as a rebindable option that stays off until the user enables it.
  public let isEnabledByDefault: Bool

  public init(id: AppShortcutID, key: Character, modifiers: EventModifiers, isEnabledByDefault: Bool = true) {
    self.id = id
    self.keyEquivalent = KeyEquivalent(key)
    self.modifiers = modifiers
    self.isEnabledByDefault = isEnabledByDefault
    self.keyCodeIsExplicit = false
    let code = AppShortcutOverride.keyCode(forDisplayedKeyEquivalent: key) ?? AppShortcutOverride.keyCode(for: key)
    self.keyCode = code
    if let code {
      self.ghosttyKeyName = AppShortcutOverride.resolvedGhosttyKeyName(for: code)
    } else {
      shortcutLogger.warning("No key code resolved for '\(key)'; Ghostty unbind may not work.")
      self.ghosttyKeyName = String(key).lowercased()
    }
  }

  public init(
    id: AppShortcutID,
    keyEquivalent: KeyEquivalent,
    ghosttyKeyName: String,
    modifiers: EventModifiers,
    isEnabledByDefault: Bool = true
  ) {
    self.id = id
    self.keyEquivalent = keyEquivalent
    self.modifiers = modifiers
    self.keyCode = nil
    self.keyCodeIsExplicit = false
    self.ghosttyKeyName = ghosttyKeyName
    self.isEnabledByDefault = isEnabledByDefault
  }

  public var displayName: String { id.displayName }

  public var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: modifiers)
  }

  public var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [ghosttyKeyName]
    return parts.joined(separator: "+")
  }

  public var ghosttyUnbindArgument: String {
    "--keybind=\(ghosttyKeybind)=unbind"
  }

  // Layout-aware display string.
  public var display: String {
    displaySymbols.joined()
  }

  public var displaySymbols: [String] {
    if let keyCode {
      return AppShortcutOverride.displaySymbols(for: keyCode, modifiers: rawModifierFlags)
    }
    return keyboardShortcut.displaySymbols
  }

  // Resolves the effective shortcut considering user overrides. Returns `nil`
  // when the user disabled it, or when it is disabled by default and unset.
  public func effective(from overrides: [AppShortcutID: AppShortcutOverride]) -> AppShortcut? {
    guard let override = overrides[id] else { return isEnabledByDefault ? self : nil }
    guard override.isEnabled else { return nil }
    return AppShortcut(id: id, override: override)
  }

  // Matches a raw key event against this shortcut. Compares key codes rather than
  // characters so the match survives Caps Lock and Shift, and requires an exact
  // modifier set so ⌘⇧P never matches a plain ⌘P binding.
  public func matches(_ event: NSEvent) -> Bool {
    guard Self.rawModifierFlags(of: event) == rawModifierFlags else { return false }
    guard let code = resolvedKeyCode else { return false }
    return event.keyCode == code
  }

  // A rebind recorded the physical key, so its code is authoritative: reverse-resolving it
  // from the character would snap a keypad or special key back onto the main-row key that
  // prints the same thing. A default only carries a character, so its code has to track
  // the live layout, or an input source switch would strand it on the wrong physical key.
  // Nil only for the special-key defaults, which no caller matches against.
  private var resolvedKeyCode: UInt16? {
    guard !keyCodeIsExplicit else { return keyCode }
    return AppShortcutOverride.keyCode(forDisplayedKeyEquivalent: keyEquivalent.character) ?? keyCode
  }

  private static func rawModifierFlags(of event: NSEvent) -> AppShortcutOverride.ModifierFlags {
    // Drop the incidental `.capsLock` / `.function` / `.numericPad` flags a key carries.
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    var flags: AppShortcutOverride.ModifierFlags = []
    if modifiers.contains(.command) { flags.insert(.command) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    return flags
  }

  // The override that binds this shortcut's default key, enabled. Used to turn on
  // a disabled-by-default shortcut from the settings toggle. nil for special keys
  // with no resolvable key code.
  public var enabledOverride: AppShortcutOverride? {
    guard let keyCode else { return nil }
    return AppShortcutOverride(keyCode: keyCode, modifiers: rawModifierFlags, isEnabled: true)
  }

  private init(id: AppShortcutID, override: AppShortcutOverride) {
    self.id = id
    self.keyEquivalent = override.keyEquivalent
    self.modifiers = override.eventModifiers
    self.keyCode = override.keyCode
    self.keyCodeIsExplicit = true
    self.ghosttyKeyName = AppShortcutOverride.resolvedGhosttyKeyName(for: override.keyCode)
    self.isEnabledByDefault = true
  }

  private var ghosttyModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("super") }
    return parts
  }

  private var rawModifierFlags: AppShortcutOverride.ModifierFlags {
    var flags: AppShortcutOverride.ModifierFlags = []
    if modifiers.contains(.command) { flags.insert(.command) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    return flags
  }

}

// MARK: - Category and grouping.

public enum AppShortcutCategory: String, CaseIterable, Sendable {
  case general
  case sidebar
  case worktrees
  case worktreeSelection
  case tabSelection
  case actions

  public var displayName: String {
    switch self {
    case .general: "General"
    case .sidebar: "Sidebar"
    case .worktrees: "Worktrees"
    case .worktreeSelection: "Worktree Selection"
    case .tabSelection: "Tab Selection"
    case .actions: "Actions"
    }
  }
}

public struct AppShortcutGroup: Identifiable {
  public let category: AppShortcutCategory
  public let shortcuts: [AppShortcut]

  public var id: String { category.rawValue }

  public init(category: AppShortcutCategory, shortcuts: [AppShortcut]) {
    self.category = category
    self.shortcuts = shortcuts
  }
}

// MARK: - Registry.

public enum AppShortcuts {
  // MARK: - Shortcut definitions.

  public static let commandPalette = AppShortcut(id: .commandPalette, key: "p", modifiers: [.command, .shift])
  public static let worktreeSwitcher = AppShortcut(id: .worktreeSwitcher, key: "p", modifiers: .command)
  public static let openSettings = AppShortcut(id: .openSettings, key: ",", modifiers: .command)
  public static let checkForUpdates = AppShortcut(id: .checkForUpdates, key: "u", modifiers: .command)
  public static let showMainWindow = AppShortcut(id: .showMainWindow, key: "0", modifiers: [.command, .shift])

  public static let toggleLeftSidebar = AppShortcut(id: .toggleLeftSidebar, key: "[", modifiers: .command)
  public static let revealInSidebar = AppShortcut(id: .revealInSidebar, key: "e", modifiers: [.command, .shift])
  // `]` expands (opens rightward), `[` collapses, mirroring the outline-view
  // Right/Left arrow convention, and pairs with ⌘[ for the sidebar toggle.
  public static let expandAllSidebarGroups = AppShortcut(
    id: .expandAllSidebarGroups, key: "]", modifiers: [.command, .control]
  )
  public static let collapseAllSidebarGroups = AppShortcut(
    id: .collapseAllSidebarGroups, key: "[", modifiers: [.command, .control]
  )

  public static let newWorktree = AppShortcut(id: .newWorktree, key: "n", modifiers: .command)
  public static let refreshWorktrees = AppShortcut(id: .refreshWorktrees, key: "r", modifiers: [.command, .shift])
  public static let archivedWorktrees = AppShortcut(id: .archivedWorktrees, key: "a", modifiers: [.command, .control])
  public static let archiveWorktree = AppShortcut(
    id: .archiveWorktree,
    keyEquivalent: .delete, ghosttyKeyName: "backspace", modifiers: .command
  )
  public static let deleteWorktree = AppShortcut(
    id: .deleteWorktree,
    keyEquivalent: .delete, ghosttyKeyName: "backspace", modifiers: [.command, .shift]
  )
  public static let confirmWorktreeAction = AppShortcut(
    id: .confirmWorktreeAction,
    keyEquivalent: .return, ghosttyKeyName: "return", modifiers: .command
  )
  public static let selectNextWorktree = AppShortcut(
    id: .selectNextWorktree,
    keyEquivalent: .downArrow, ghosttyKeyName: "arrow_down", modifiers: [.command, .control]
  )
  public static let selectPreviousWorktree = AppShortcut(
    id: .selectPreviousWorktree,
    keyEquivalent: .upArrow, ghosttyKeyName: "arrow_up", modifiers: [.command, .control]
  )
  public static let worktreeHistoryBack = AppShortcut(
    id: .worktreeHistoryBack,
    keyEquivalent: .leftArrow, ghosttyKeyName: "arrow_left", modifiers: [.command, .control]
  )
  public static let worktreeHistoryForward = AppShortcut(
    id: .worktreeHistoryForward,
    keyEquivalent: .rightArrow, ghosttyKeyName: "arrow_right", modifiers: [.command, .control]
  )

  public static let selectWorktree1 = AppShortcut(id: .selectWorktree(1), key: "1", modifiers: [.control])
  public static let selectWorktree2 = AppShortcut(id: .selectWorktree(2), key: "2", modifiers: [.control])
  public static let selectWorktree3 = AppShortcut(id: .selectWorktree(3), key: "3", modifiers: [.control])
  public static let selectWorktree4 = AppShortcut(id: .selectWorktree(4), key: "4", modifiers: [.control])
  public static let selectWorktree5 = AppShortcut(id: .selectWorktree(5), key: "5", modifiers: [.control])
  public static let selectWorktree6 = AppShortcut(id: .selectWorktree(6), key: "6", modifiers: [.control])
  public static let selectWorktree7 = AppShortcut(id: .selectWorktree(7), key: "7", modifiers: [.control])
  public static let selectWorktree8 = AppShortcut(id: .selectWorktree(8), key: "8", modifiers: [.control])
  public static let selectWorktree9 = AppShortcut(id: .selectWorktree(9), key: "9", modifiers: [.control])

  public static let selectTab1 = AppShortcut(id: .selectTab(1), key: "1", modifiers: [.command])
  public static let selectTab2 = AppShortcut(id: .selectTab(2), key: "2", modifiers: [.command])
  public static let selectTab3 = AppShortcut(id: .selectTab(3), key: "3", modifiers: [.command])
  public static let selectTab4 = AppShortcut(id: .selectTab(4), key: "4", modifiers: [.command])
  public static let selectTab5 = AppShortcut(id: .selectTab(5), key: "5", modifiers: [.command])
  public static let selectTab6 = AppShortcut(id: .selectTab(6), key: "6", modifiers: [.command])
  public static let selectTab7 = AppShortcut(id: .selectTab(7), key: "7", modifiers: [.command])
  public static let selectTab8 = AppShortcut(id: .selectTab(8), key: "8", modifiers: [.command])
  public static let selectTab9 = AppShortcut(id: .selectTab(9), key: "9", modifiers: [.command])

  public static let openWorktree = AppShortcut(id: .openWorktree, key: "o", modifiers: .command)
  public static let revealInFinder = AppShortcut(id: .revealInFinder, key: "r", modifiers: [.command, .option])
  public static let openRepository = AppShortcut(id: .openRepository, key: "o", modifiers: [.command, .shift])
  public static let addRemoteRepository = AppShortcut(
    id: .addRemoteRepository, key: "k", modifiers: [.command, .shift]
  )
  public static let cloneRepository = AppShortcut(
    id: .cloneRepository, key: "o", modifiers: [.command, .option, .shift], isEnabledByDefault: false
  )
  public static let openPullRequest = AppShortcut(id: .openPullRequest, key: "g", modifiers: [.command, .control])
  public static let copyPath = AppShortcut(id: .copyPath, key: "c", modifiers: [.command, .shift])
  public static let runScript = AppShortcut(id: .runScript, key: "r", modifiers: .command)
  public static let stopRunScript = AppShortcut(id: .stopRunScript, key: ".", modifiers: .command)
  public static let jumpToLatestUnread = AppShortcut(
    id: .jumpToLatestUnread, key: "u", modifiers: [.command, .shift]
  )
  public static let togglePullRequestInspector = AppShortcut(
    id: .togglePullRequestInspector, key: "g", modifiers: [.command, .option]
  )
  public static let toggleNotificationsInspector = AppShortcut(
    id: .toggleNotificationsInspector, key: "n", modifiers: [.command, .option]
  )

  public static let worktreeSelection: [AppShortcut] = [
    selectWorktree1, selectWorktree2, selectWorktree3, selectWorktree4, selectWorktree5,
    selectWorktree6, selectWorktree7, selectWorktree8, selectWorktree9,
  ]

  public static let tabSelection: [AppShortcut] = [
    selectTab1, selectTab2, selectTab3, selectTab4, selectTab5,
    selectTab6, selectTab7, selectTab8, selectTab9,
  ]

  public static func worktreeSelectionShortcutDisplay(
    atSlot index: Int,
    overrides: [AppShortcutID: AppShortcutOverride]
  ) -> String? {
    guard worktreeSelection.indices.contains(index) else { return nil }
    return worktreeSelection[index].effective(from: overrides)?.display
  }

  public static func tabSelectionShortcutDisplays(
    overrides: [AppShortcutID: AppShortcutOverride]
  ) -> [String?] {
    tabSelection.map { $0.effective(from: overrides)?.display }
  }

  // Drops disabled bindings and out-of-range slots so neither leaves a stale NSMenuItem keyEquivalent.
  public static func activeWorktreeSelectionSlots(
    overrides: [AppShortcutID: AppShortcutOverride],
    orderedRowsCount: Int
  ) -> [(index: Int, shortcut: AppShortcut)] {
    worktreeSelection.enumerated().compactMap { index, shortcut in
      guard index < orderedRowsCount else { return nil }
      guard let effective = shortcut.effective(from: overrides) else { return nil }
      return (index, effective)
    }
  }

  // MARK: - Groups.

  public static let groups: [AppShortcutGroup] = [
    AppShortcutGroup(
      category: .general,
      shortcuts: [worktreeSwitcher, commandPalette, openSettings, checkForUpdates, showMainWindow]
    ),
    AppShortcutGroup(
      category: .sidebar,
      shortcuts: [toggleLeftSidebar, revealInSidebar, expandAllSidebarGroups, collapseAllSidebarGroups]
    ),
    AppShortcutGroup(
      category: .worktrees,
      shortcuts: [
        newWorktree, refreshWorktrees, archivedWorktrees, archiveWorktree,
        deleteWorktree, confirmWorktreeAction, selectNextWorktree, selectPreviousWorktree,
        worktreeHistoryBack, worktreeHistoryForward,
      ]
    ),
    AppShortcutGroup(category: .worktreeSelection, shortcuts: worktreeSelection),
    AppShortcutGroup(category: .tabSelection, shortcuts: tabSelection),
    AppShortcutGroup(
      category: .actions,
      shortcuts: [
        openWorktree, revealInFinder, openRepository, addRemoteRepository, cloneRepository,
        openPullRequest, copyPath, runScript, stopRunScript, jumpToLatestUnread,
        togglePullRequestInspector, toggleNotificationsInspector,
      ]
    ),
  ]

  // MARK: - All shortcuts.

  public static let all: [AppShortcut] = groups.flatMap(\.shortcuts)

  // The enabled override binding a disabled-by-default shortcut to its default
  // key, so the settings toggle can turn it on. nil for an enabled-by-default or
  // unknown shortcut, which needs no override to be active.
  public static func defaultEnabledOverride(for id: AppShortcutID) -> AppShortcutOverride? {
    guard let shortcut = all.first(where: { $0.id == id }), !shortcut.isEnabledByDefault else { return nil }
    return shortcut.enabledOverride
  }

  // MARK: - Tab selection Ghostty bindings.

  // Ghostty `goto_tab` bindings for worktree selection, derived from the user's
  // effective shortcuts instead of a fixed list. A disabled shortcut produces no
  // binding, so its chord (e.g. ⌃6) reaches the terminal instead of being captured.
  // A remapped shortcut moves the binding to the chosen key. The physical `digit_N`
  // variant is emitted only while the binding stays the default Control+digit, so
  // non-US keyboard layouts keep working.
  public static func tabSelectionGhosttyKeybindArguments(
    from overrides: [AppShortcutID: AppShortcutOverride]
  ) -> [String] {
    worktreeSelection.flatMap { shortcut -> [String] in
      guard case .selectWorktree(let slot) = shortcut.id,
        let effective = shortcut.effective(from: overrides)
      else {
        return []
      }
      let tabIndex = slot == 0 ? 10 : slot
      var arguments = ["--keybind=\(effective.ghosttyKeybind)=goto_tab:\(tabIndex)"]
      if effective.ghosttyKeybind == "ctrl+\(slot)" {
        arguments.append("--keybind=ctrl+digit_\(slot)=goto_tab:\(tabIndex)")
      }
      return arguments
    }
  }

  // MARK: - Ghostty CLI arguments.

  public static var ghosttyCLIKeybindArguments: [String] {
    ghosttyCLIKeybindArguments(from: [:])
  }

  public static func ghosttyCLIKeybindArguments(from overrides: [AppShortcutID: AppShortcutOverride]) -> [String] {
    let effectiveShortcuts = all.compactMap { $0.effective(from: overrides) }
    return effectiveShortcuts.map(\.ghosttyUnbindArgument) + tabSelectionGhosttyKeybindArguments(from: overrides)
  }

  // MARK: - Conflict detection.

  // Computes conflict warnings for all shortcuts given the current overrides.
  public static func conflictWarnings(
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
  // Always returns the same view type so menu-bar CommandGroups don't lose identity
  // when the shortcut hydrates from disk; that flip strips Tahoe arrangement items.
  public func appKeyboardShortcut(_ shortcut: AppShortcut?) -> some View {
    keyboardShortcut(shortcut.map { KeyboardShortcut($0.keyEquivalent, modifiers: $0.modifiers) })
  }
}
