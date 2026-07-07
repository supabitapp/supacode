import AppKit
import Foundation
import GhosttyKit
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct GhosttySurfaceViewTests {
  @Test func normalizedWorkingDirectoryPathRemovesTrailingSlashForNonRootPath() {
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode/")
        == "/Users/onevcat/Sync/github/supacode"
    )
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode///")
        == "/Users/onevcat/Sync/github/supacode"
    )
  }

  @Test func normalizedWorkingDirectoryPathKeepsRootPath() {
    #expect(GhosttySurfaceView.normalizedWorkingDirectoryPath("/") == "/")
  }

  @Test func accessibilityLineCountsLineBreaksUpToIndex() {
    let content = "alpha\nbeta\ngamma"

    #expect(GhosttySurfaceView.accessibilityLine(for: 0, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 5, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 6, in: content) == 1)
    #expect(GhosttySurfaceView.accessibilityLine(for: content.count, in: content) == 2)
  }

  @Test func accessibilityStringReturnsSubstringForValidRange() {
    let content = "alpha\nbeta"

    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 6, length: 4),
        in: content
      ) == "beta"
    )
    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 99, length: 1),
        in: content
      ) == nil
    )
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionSuppressesMatchingKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.1))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionIgnoresDifferentKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 50, timestamp: 10.1))
    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.2))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionExpires() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 49, timestamp: 11.1))
    #expect(suppression.isExpired(at: 11.1))
  }

  private static func keyEvent(
    chars: String,
    ignoringModifiers: String,
    modifiers: NSEvent.ModifierFlags
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: chars,
      charactersIgnoringModifiers: ignoringModifiers,
      isARepeat: false,
      keyCode: 4
    )!
  }

  private static func item(action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = NSMenuItem(title: "Item", action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = mask
    return item
  }

  private static func menu(action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(action: action, keyEquivalent: keyEquivalent, mask: mask))
    return menu
  }

  /// The `⌥⌘H` chord that collides with the Hide Others built-in.
  private static func optionCommandH() -> NSEvent {
    keyEvent(chars: "˙", ignoringModifiers: "h", modifiers: [.command, .option])
  }

  private static func commandV(modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
    keyEvent(chars: "v", ignoringModifiers: "v", modifiers: modifiers)
  }

  /// The Hide Others built-in item bound to `⌥⌘H`.
  private static func hideOthersItem() -> NSMenuItem {
    item(
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      mask: [.command, .option]
    )
  }

  @Test func forwardableMenuItemSkipsHideOthersBuiltIn() {
    let menu = Self.menu(
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      mask: [.command, .option]
    )

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) == nil)
  }

  @Test func imageOnlyCommandVRoutesForClaudeImagePaste() {
    #expect(
      GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotOverrideTextOrFilePaste() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.string, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.fileURL, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVRequiresExactCommandVAndSupportedAgent() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(modifiers: [.command, .shift]),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.opencode],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotInterruptGhosttyKeySequences() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: true,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 1
      )
    )
  }

  @Test func imageCommandVIgnoresRichTextAndUrlRepresentations() {
    // Browser / Preview image copies carry TIFF alongside RTF, HTML, or a URL; those paste as text.
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [NSPasteboard.PasteboardType("public.rtf"), .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [NSPasteboard.PasteboardType("public.html"), .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.URL, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVRoutesForNonTiffImageType() {
    #expect(
      GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.png],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotRouteWithoutImageType() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: nil,
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func nativeImagePasteEventConvertsCommandVToControlV() throws {
    let converted = try #require(GhosttySurfaceView.nativeImagePasteEvent(from: Self.commandV()))

    #expect(converted.characters == "v")
    #expect(converted.charactersIgnoringModifiers == "v")
    #expect(converted.modifierFlags.intersection([.shift, .control, .option, .command]) == [.control])
  }

  @Test func forwardableMenuItemKeepsAppOwnedItem() {
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) != nil)
  }

  @Test func forwardableMenuItemSkipsHideBuiltIn() {
    let event = Self.keyEvent(chars: "h", ignoringModifiers: "h", modifiers: [.command])
    let menu = Self.menu(action: #selector(NSApplication.hide(_:)), keyEquivalent: "h", mask: [.command])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) == nil)
  }

  @Test func forwardableMenuItemHonorsImplicitShiftForAppOwnedItem() {
    let event = Self.keyEvent(chars: "A", ignoringModifiers: "a", modifiers: [.command, .shift])
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "A", mask: [.command])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) != nil)
  }

  @Test func forwardableMenuItemRecursesIntoSubmenusAndSkipsBuiltIns() {
    let builtInSubmenu = NSMenu()
    builtInSubmenu.addItem(Self.hideOthersItem())
    let builtInRoot = NSMenu()
    builtInRoot.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = builtInSubmenu
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: builtInRoot) == nil)

    let appSubmenu = NSMenu()
    appSubmenu.addItem(Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option]))
    let appRoot = NSMenu()
    appRoot.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = appSubmenu
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: appRoot) != nil)
  }

  @Test func forwardableMenuItemResolvesAppOwnedItemSharingChordWithBuiltIn() {
    let menu = NSMenu()
    menu.addItem(Self.hideOthersItem())
    let appOwned = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option])
    menu.addItem(appOwned)

    // The built-in is listed first, so this pins that we dispatch the app-owned item, never Hide Others.
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) === appOwned)
  }

  @Test func forwardableMenuItemIgnoresBuiltInWithNonMatchingMask() {
    let event = Self.keyEvent(chars: "h", ignoringModifiers: "h", modifiers: [.command])
    let menu = NSMenu()
    menu.addItem(Self.hideOthersItem())
    let appOwned = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command])
    menu.addItem(appOwned)

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) === appOwned)
  }

  @Test func menuHasSystemManagedConflictDetectsBuiltInSharingChord() {
    // A custom `close_surface` remapped onto ⌘M collides with Minimize, so the chord must
    // stay with Ghostty instead of forwarding (which could fire Minimize).
    let event = Self.keyEvent(chars: "m", ignoringModifiers: "m", modifiers: [.command])
    let menu = NSMenu()
    menu.addItem(Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "m", mask: [.command]))
    menu.addItem(Self.item(action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", mask: [.command]))

    #expect(GhosttySurfaceView.menuHasSystemManagedConflict(for: event, in: menu))
  }

  @Test func menuHasSystemManagedConflictIgnoresAppOwnedOnlyChord() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "w", mask: [.command])

    #expect(!GhosttySurfaceView.menuHasSystemManagedConflict(for: event, in: menu))
  }

  @Test func menuHasSystemManagedConflictRecursesIntoSubmenus() {
    let submenu = NSMenu()
    submenu.addItem(Self.hideOthersItem())
    let root = NSMenu()
    root.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = submenu

    #expect(GhosttySurfaceView.menuHasSystemManagedConflict(for: Self.optionCommandH(), in: root))
  }

  @Test func menuItemMatchesExactCommandChord() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "w", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemRejectsSupersetModifierChord() {
    // `⌘,` (Settings) must not match `⌘⇧,` (Ghostty's reload_config).
    let event = Self.keyEvent(chars: ",", ignoringModifiers: ",", modifiers: [.command, .shift])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: ",", mask: [.command])

    #expect(!GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemRejectsEmptyKeyEquivalent() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "", mask: [.command])

    #expect(!GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemHonorsImplicitShiftBothDirections() {
    // An uppercase `keyEquivalent` encodes shift: it matches ⌘⇧A but not plain ⌘a.
    let shiftEvent = Self.keyEvent(chars: "A", ignoringModifiers: "a", modifiers: [.command, .shift])
    let plainEvent = Self.keyEvent(chars: "a", ignoringModifiers: "a", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "A", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: shiftEvent))
    #expect(!GhosttySurfaceView.menuItem(item, matches: plainEvent))
  }

  private final class MenuActionTarget: NSObject {
    var fired = false
    @objc func fire(_ sender: Any?) { fired = true }
  }

  @Test func performMenuItemDispatchesEnabledItem() {
    let target = MenuActionTarget()
    let item = NSMenuItem(title: "Go", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.isEnabled = true

    #expect(GhosttySurfaceView.performMenuItem(item))
    #expect(target.fired)
  }

  @Test func performMenuItemRejectsDisabledItem() {
    let target = MenuActionTarget()
    let item = NSMenuItem(title: "Off", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.isEnabled = false

    #expect(!GhosttySurfaceView.performMenuItem(item))
    #expect(!target.fired)
  }

  @Test func performMenuItemRejectsItemWithoutAction() {
    let item = NSMenuItem(title: "Inert", action: nil, keyEquivalent: "")
    item.isEnabled = true

    #expect(!GhosttySurfaceView.performMenuItem(item))
  }

  @Test func dispatchForwardableChordFiresResolvedItemDirectlyOnConflict() {
    // A custom `close_surface` on ⌘M shares the chord with Minimize: dispatch must fire the resolved
    // app item directly (so its explicit-close action runs) instead of the native path, which could
    // fire Minimize.
    let target = MenuActionTarget()
    let event = Self.keyEvent(chars: "m", ignoringModifiers: "m", modifiers: [.command])
    let menu = NSMenu()
    menu.autoenablesItems = false
    let appItem = NSMenuItem(title: "Close", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "m")
    appItem.keyEquivalentModifierMask = [.command]
    appItem.target = target
    appItem.isEnabled = true
    menu.addItem(appItem)
    menu.addItem(Self.item(action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", mask: [.command]))

    #expect(GhosttySurfaceView.dispatchForwardableChord(appItem, for: event, in: menu))
    #expect(target.fired)
  }

  @Test func isSystemManagedMenuItemClassifiesActions() {
    let hideOthers = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: ""
    )
    #expect(GhosttySurfaceView.isSystemManagedMenuItem(hideOthers))

    let appOwned = NSMenuItem(title: "Custom", action: Selector(("appOwnedAction:")), keyEquivalent: "")
    #expect(!GhosttySurfaceView.isSystemManagedMenuItem(appOwned))

    let noAction = NSMenuItem(title: "Inert", action: nil, keyEquivalent: "")
    #expect(!GhosttySurfaceView.isSystemManagedMenuItem(noAction))
  }

  @Test func reportedSurfaceSizeUsesScrollContentWidth() {
    #expect(
      GhosttySurfaceScrollView.reportedSurfaceSize(
        scrollContentSize: CGSize(width: 799, height: 600),
        surfaceFrameSize: CGSize(width: 816, height: 600)
      ) == CGSize(width: 799, height: 600)
    )
  }

  @Test func wrapperSafeAreaInsetsAreZero() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    let wrapper = GhosttySurfaceScrollView(surfaceView: surfaceView)

    #expect(wrapper.safeAreaInsets.top == 0)
    #expect(wrapper.safeAreaInsets.left == 0)
    #expect(wrapper.safeAreaInsets.bottom == 0)
    #expect(wrapper.safeAreaInsets.right == 0)
  }
}
