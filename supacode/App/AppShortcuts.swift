import SwiftUI

struct AppShortcut {
  let key: Character
  let modifiers: EventModifiers

  var keyEquivalent: KeyEquivalent {
    KeyEquivalent(key)
  }

  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: modifiers)
  }

  var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [String(key).lowercased()]
    return parts.joined(separator: "+")
  }

  var display: String {
    let parts = displayModifierParts + [String(key).uppercased()]
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
  static let newWorktree = AppShortcut(key: "n", modifiers: .command)
  static let openSettings = AppShortcut(key: ",", modifiers: .command)
  static let openFinder = AppShortcut(key: "o", modifiers: .command)
  static let copyPath = AppShortcut(key: "c", modifiers: [.command, .shift])
  static let openRepository = AppShortcut(key: "o", modifiers: [.command, .shift])
  static let openPullRequest = AppShortcut(key: "g", modifiers: [.command, .control])
  static let toggleLeftSidebar = AppShortcut(key: "[", modifiers: .command)
  static let refreshWorktrees = AppShortcut(key: "r", modifiers: [.command, .shift])
  static let runScript = AppShortcut(key: "r", modifiers: .command)
  static let stopRunScript = AppShortcut(key: ".", modifiers: .command)
  static let checkForUpdates = AppShortcut(key: "u", modifiers: .command)
  static let toggleDiffPanel = AppShortcut(key: "]", modifiers: .command)
  static let archivedWorktrees = AppShortcut(key: "a", modifiers: [.command, .control])
  static let selectWorktree1 = AppShortcut(key: "1", modifiers: [.command, .control])
  static let selectWorktree2 = AppShortcut(key: "2", modifiers: [.command, .control])
  static let selectWorktree3 = AppShortcut(key: "3", modifiers: [.command, .control])
  static let selectWorktree4 = AppShortcut(key: "4", modifiers: [.command, .control])
  static let selectWorktree5 = AppShortcut(key: "5", modifiers: [.command, .control])
  static let selectWorktree6 = AppShortcut(key: "6", modifiers: [.command, .control])
  static let selectWorktree7 = AppShortcut(key: "7", modifiers: [.command, .control])
  static let selectWorktree8 = AppShortcut(key: "8", modifiers: [.command, .control])
  static let selectWorktree9 = AppShortcut(key: "9", modifiers: [.command, .control])
  static let selectWorktree0 = AppShortcut(key: "0", modifiers: [.command, .control])
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
  static let all: [AppShortcut] = [
    newWorktree,
    openSettings,
    openFinder,
    copyPath,
    openRepository,
    openPullRequest,
    toggleLeftSidebar,
    toggleDiffPanel,
    refreshWorktrees,
    runScript,
    stopRunScript,
    checkForUpdates,
    archivedWorktrees,
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
}
