import SwiftUI

struct AppShortcut {
  let name: String
  let keyEquivalent: KeyEquivalent
  let modifiers: EventModifiers
  private let ghosttyKeyName: String

  init(name: String, key: Character, modifiers: EventModifiers) {
    self.name = name
    self.keyEquivalent = KeyEquivalent(key)
    self.modifiers = modifiers
    self.ghosttyKeyName = String(key).lowercased()
  }

  init(name: String, keyEquivalent: KeyEquivalent, ghosttyKeyName: String, modifiers: EventModifiers) {
    self.name = name
    self.keyEquivalent = keyEquivalent
    self.modifiers = modifiers
    self.ghosttyKeyName = ghosttyKeyName
  }

  init(name: String, override: AppShortcutOverride) {
    self.name = name
    self.keyEquivalent = override.keyboardShortcut.key
    self.modifiers = override.eventModifiers
    self.ghosttyKeyName = override.ghosttyKeybind.split(separator: "+").last.map(String.init) ?? ""
  }

  func effective(from settings: GlobalSettings) -> AppShortcut {
    guard let override = settings.shortcutOverrides[name] else { return self }
    return AppShortcut(name: name, override: override)
  }

  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: modifiers)
  }

  var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [ghosttyKeyName]
    return parts.joined(separator: "+")
  }

  var ghosttyUnbindArgument: String {
    "--keybind=\(ghosttyKeybind)=unbind"
  }

  var displayName: String {
    var result = ""
    for (index, char) in name.enumerated() {
      if index > 0 && char.isUppercase {
        result.append(" ")
      }
      result.append(index == 0 ? char.uppercased() : String(char))
    }
    return result
  }

  var display: String {
    let parts = displayModifierParts + [keyEquivalent.display]
    return parts.joined()
  }

  var displaySymbols: [String] {
    display.map { String($0) }
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

  static let newWorktree = AppShortcut(name: "newWorktree", key: "n", modifiers: .command)
  static let openSettings = AppShortcut(name: "openSettings", key: ",", modifiers: .command)
  static let openFinder = AppShortcut(name: "openFinder", key: "o", modifiers: .command)
  static let copyPath = AppShortcut(name: "copyPath", key: "c", modifiers: [.command, .shift])
  static let openRepository = AppShortcut(name: "openRepository", key: "o", modifiers: [.command, .shift])
  static let openPullRequest = AppShortcut(name: "openPullRequest", key: "g", modifiers: [.command, .control])
  static let toggleLeftSidebar = AppShortcut(name: "toggleLeftSidebar", key: "[", modifiers: .command)
  static let refreshWorktrees = AppShortcut(name: "refreshWorktrees", key: "r", modifiers: [.command, .shift])
  static let runScript = AppShortcut(name: "runScript", key: "r", modifiers: .command)
  static let stopRunScript = AppShortcut(name: "stopRunScript", key: ".", modifiers: .command)
  static let checkForUpdates = AppShortcut(name: "checkForUpdates", key: "u", modifiers: .command)
  static let archiveWorktree = AppShortcut(
    name: "archiveWorktree",
    keyEquivalent: .delete, ghosttyKeyName: "backspace", modifiers: .command
  )
  static let deleteWorktree = AppShortcut(
    name: "deleteWorktree",
    keyEquivalent: .delete, ghosttyKeyName: "backspace", modifiers: [.command, .shift]
  )
  static let confirmWorktreeAction = AppShortcut(
    name: "confirmWorktreeAction",
    keyEquivalent: .return, ghosttyKeyName: "return", modifiers: .command
  )
  static let archivedWorktrees = AppShortcut(name: "archivedWorktrees", key: "a", modifiers: [.command, .control])
  static let find = AppShortcut(name: "find", key: "f", modifiers: .command)
  static let findNext = AppShortcut(name: "findNext", key: "g", modifiers: .command)
  static let findPrevious = AppShortcut(name: "findPrevious", key: "g", modifiers: [.command, .shift])
  static let hideFindBar = AppShortcut(name: "hideFindBar", key: "f", modifiers: [.command, .shift])
  static let useSelectionForFind = AppShortcut(name: "useSelectionForFind", key: "e", modifiers: .command)
  static let commandPalette = AppShortcut(name: "commandPalette", key: "p", modifiers: .command)
  static let selectNextWorktree = AppShortcut(
    name: "selectNextWorktree",
    keyEquivalent: .downArrow, ghosttyKeyName: "arrow_down", modifiers: [.command, .control]
  )
  static let selectPreviousWorktree = AppShortcut(
    name: "selectPreviousWorktree",
    keyEquivalent: .upArrow, ghosttyKeyName: "arrow_up", modifiers: [.command, .control]
  )
  static let selectWorktree1 = AppShortcut(name: "selectWorktree1", key: "1", modifiers: [.control])
  static let selectWorktree2 = AppShortcut(name: "selectWorktree2", key: "2", modifiers: [.control])
  static let selectWorktree3 = AppShortcut(name: "selectWorktree3", key: "3", modifiers: [.control])
  static let selectWorktree4 = AppShortcut(name: "selectWorktree4", key: "4", modifiers: [.control])
  static let selectWorktree5 = AppShortcut(name: "selectWorktree5", key: "5", modifiers: [.control])
  static let selectWorktree6 = AppShortcut(name: "selectWorktree6", key: "6", modifiers: [.control])
  static let selectWorktree7 = AppShortcut(name: "selectWorktree7", key: "7", modifiers: [.control])
  static let selectWorktree8 = AppShortcut(name: "selectWorktree8", key: "8", modifiers: [.control])
  static let selectWorktree9 = AppShortcut(name: "selectWorktree9", key: "9", modifiers: [.control])
  static let selectWorktree0 = AppShortcut(name: "selectWorktree0", key: "0", modifiers: [.control])
  static let worktreeSelection: [AppShortcut] = [
    selectWorktree1,
    selectWorktree2,
    selectWorktree3,
    selectWorktree4,
    selectWorktree5,
    selectWorktree6,
    selectWorktree7,
    selectWorktree8,
    selectWorktree9,
    selectWorktree0,
  ]

  static let tabSelectionGhosttyKeybindArguments: [String] = tabSelectionBindings.flatMap { binding in
    [
      "--keybind=ctrl+\(binding.unicode)=goto_tab:\(binding.tabIndex)",
      "--keybind=ctrl+\(binding.physical)=goto_tab:\(binding.tabIndex)",
    ]
  }

  static func ghosttyCLIKeybindArguments(from settings: GlobalSettings) -> [String] {
    effectiveAll(from: settings).map(\.ghosttyUnbindArgument) + tabSelectionGhosttyKeybindArguments
  }

  static let all: [AppShortcut] = [
    newWorktree,
    openSettings,
    openFinder,
    copyPath,
    openRepository,
    openPullRequest,
    toggleLeftSidebar,
    refreshWorktrees,
    runScript,
    stopRunScript,
    checkForUpdates,
    archiveWorktree,
    deleteWorktree,
    confirmWorktreeAction,
    archivedWorktrees,
    find,
    findNext,
    findPrevious,
    hideFindBar,
    useSelectionForFind,
    commandPalette,
    selectNextWorktree,
    selectPreviousWorktree,
    selectWorktree1,
    selectWorktree2,
    selectWorktree3,
    selectWorktree4,
    selectWorktree5,
    selectWorktree6,
    selectWorktree7,
    selectWorktree8,
    selectWorktree9,
    selectWorktree0,
  ]

  static func effectiveAll(from settings: GlobalSettings) -> [AppShortcut] {
    all.map { $0.effective(from: settings) }
  }
}
