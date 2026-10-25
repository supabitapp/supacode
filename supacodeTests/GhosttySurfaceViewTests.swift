import AppKit
import Clocks
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

  @Test func accessibilityLineCountsUTF16Offsets() {
    let content = "👋\nbeta"

    #expect(GhosttySurfaceView.accessibilityLine(for: 2, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 3, in: content) == 1)
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

  @Test func accessibilityStringDecodesRangesSplittingASurrogatePair() {
    let content = "a👋b"

    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 1, length: 2), in: content) == "👋")
    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 0, length: 2), in: content) == "a\u{FFFD}")
    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 1, length: Int.max), in: content) == nil)
  }

  @Test func accessibilityStringRejectsRangesOutsideTheUTF16Bounds() {
    let content = "a👋"

    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 3, length: 0), in: content) == "")
    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 4, length: 0), in: content) == nil)
    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 2, length: 2), in: content) == nil)
    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: -1, length: 1), in: content) == nil)
    #expect(GhosttySurfaceView.accessibilityString(for: NSRange(location: 0, length: -1), in: content) == nil)
  }

  @Test func shouldHealOcclusionOnlyFiresForLatchedSurfaceAtKeyWindow() {
    // Not latched (nil or visible): never heal.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: nil, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: false
      ))
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: true, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: false
      ))
    // Latched but window not key: never heal.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: false, windowIsVisible: true, requiresVisibleWindow: false
      ))
    // Typing at a key window heals even when the window server reports covered.
    #expect(
      GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: false, requiresVisibleWindow: false
      ))
    // Pointer events additionally require a visible report.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: false, requiresVisibleWindow: true
      ))
    #expect(
      GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: true
      ))
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

    nonisolated deinit {}

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
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }
    let wrapper = GhosttySurfaceScrollView(surfaceView: surfaceView)

    #expect(wrapper.safeAreaInsets.top == 0)
    #expect(wrapper.safeAreaInsets.left == 0)
    #expect(wrapper.safeAreaInsets.bottom == 0)
    #expect(wrapper.safeAreaInsets.right == 0)
  }

  // A remount must reparent the same wrapper, so the live IOSurface keeps its
  // frames instead of the renderer rebuilding at zero size on every switch.
  @Test func hostedViewReturnsTheSameWrapperAcrossRemounts() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }

    let wrapper = surfaceView.hostedView()
    #expect(surfaceView.hostedView() === wrapper)
    // The reuse guard in the content host keys off `scrollWrapper`; it has to
    // point at the very wrapper `hostedView()` vends.
    #expect(surfaceView.scrollWrapper === wrapper)
  }

  // `closeSurface` must clear the cached wrapper so the surface<->wrapper cycle
  // is broken: proven by `hostedView()` vending a fresh instance afterwards. If
  // the release is ever dropped, the same wrapper comes back and both leak.
  @Test func closeSurfaceClearsTheCachedWrapper() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }

    let first = surfaceView.hostedView()
    surfaceView.closeSurface()
    let second = surfaceView.hostedView()

    #expect(first !== second)
    #expect(surfaceView.scrollWrapper === second)
  }

  // `closeSurface` detaches synchronously (surface cleared, view hidden so the
  // "[Process exited]" overlay can't flash during a collapse) and defers the
  // costly `ghostty_surface_free` off the turn, and a second close is a safe
  // no-op. Only the hide needs a live renderer, absent when the display sleeps;
  // the synchronous clear and the double-close no-op hold on both paths.
  @Test func closeSurfaceDetachesSynchronouslyAndHidesTheView() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    let hadLiveRenderer = surfaceView.surface != nil

    surfaceView.closeSurface()
    #expect(surfaceView.surface == nil)
    if hadLiveRenderer {
      #expect(surfaceView.isHidden)
    }

    // Idempotent: the surface is already gone, so this must not double-free.
    surfaceView.closeSurface()
    #expect(surfaceView.surface == nil)
  }

  @Test func cachedValueServesTheFetchUntilTheDurationElapses() async {
    let clock = TestClock()
    let cache = GhosttySurfaceView.CachedValue<Int, TestClock<Duration>>(
      clock: clock,
      duration: .milliseconds(500)
    )
    var fetches = 0
    let fetch = {
      fetches += 1
      return fetches
    }

    #expect(cache.value(orFetch: fetch) == 1)
    #expect(cache.value(orFetch: fetch) == 1)
    await clock.advance(by: .milliseconds(499))
    #expect(cache.value(orFetch: fetch) == 1)
    await clock.advance(by: .milliseconds(1))
    #expect(cache.value(orFetch: fetch) == 2)
    // The refetch restarts the window.
    await clock.advance(by: .milliseconds(499))
    #expect(cache.value(orFetch: fetch) == 2)
    await clock.advance(by: .milliseconds(1))
    #expect(cache.value(orFetch: fetch) == 3)
  }

  @Test func cachedValueRefetchesAfterInvalidation() {
    let cache = GhosttySurfaceView.CachedValue<Int, TestClock<Duration>>(
      clock: TestClock(),
      duration: .milliseconds(500)
    )
    var fetches = 0
    let fetch = {
      fetches += 1
      return fetches
    }

    #expect(cache.value(orFetch: fetch) == 1)
    cache.invalidate()
    #expect(cache.value(orFetch: fetch) == 2)
  }

  @Test func cachedValueDoesNotCacheAFailedFetch() {
    let cache = GhosttySurfaceView.CachedValue<Int, TestClock<Duration>>(
      clock: TestClock(),
      duration: .milliseconds(500)
    )
    var results: [Int?] = [nil, 7, 8]
    let fetch = { results.removeFirst() }

    #expect(cache.value(orFetch: fetch) == nil)
    #expect(cache.value(orFetch: fetch) == 7)
    #expect(cache.value(orFetch: fetch) == 7)
    #expect(results == [8])
  }

  @Test func cachedValueDropsTheExpiredValueWhenTheRefetchFails() async {
    let clock = TestClock()
    let cache = GhosttySurfaceView.CachedValue<Int, TestClock<Duration>>(
      clock: clock,
      duration: .milliseconds(500)
    )
    var results: [Int?] = [5, nil, 6]
    let fetch = { results.removeFirst() }

    #expect(cache.value(orFetch: fetch) == 5)
    await clock.advance(by: .milliseconds(500))
    #expect(cache.value(orFetch: fetch) == nil)
    #expect(cache.value(orFetch: fetch) == 6)
    #expect(results.isEmpty)
  }

  @Test func flagsChangedReachesTheHoveredSurfaceUnlessItIsTheKeyResponder() {
    let hovered = NSObject()
    let holder = NSObject()

    #expect(targets(hovered: hovered, holders: [], isRelease: false, keyResponder: nil) == [hovered])
    #expect(targets(hovered: hovered, holders: [], isRelease: false, keyResponder: hovered).isEmpty)
    // A press never reaches a holder the pointer has left.
    #expect(targets(hovered: hovered, holders: [holder], isRelease: false, keyResponder: nil) == [hovered])
    #expect(targets(hovered: nil, holders: [holder], isRelease: false, keyResponder: nil).isEmpty)
  }

  @Test func flagsChangedReleaseReachesEverySurfaceThatTookThePress() {
    let hovered = NSObject()
    let first = NSObject()
    let second = NSObject()

    #expect(targets(hovered: nil, holders: [first, second], isRelease: true, keyResponder: nil) == [first, second])
    #expect(targets(hovered: hovered, holders: [first], isRelease: true, keyResponder: nil) == [hovered, first])
    #expect(targets(hovered: first, holders: [first], isRelease: true, keyResponder: nil) == [first])
    // The key responder already gets the release through the responder chain.
    #expect(
      targets(hovered: hovered, holders: [first, second], isRelease: true, keyResponder: first) == [hovered, second])
    #expect(targets(hovered: hovered, holders: [first], isRelease: true, keyResponder: hovered) == [first])
  }

  @Test func modifierActionDistinguishesPressReleaseAndNonModifiers() throws {
    let leftCommand = CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
    let rightCommand = CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))
    let leftShift = CGEventFlags(rawValue: UInt64(NX_DEVICELSHIFTKEYMASK))
    let rightShift = CGEventFlags(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))

    #expect(try modifierAction(keyCode: 0x37, flags: .maskCommand) == GHOSTTY_ACTION_PRESS)
    #expect(try modifierAction(keyCode: 0x37, flags: []) == GHOSTTY_ACTION_RELEASE)
    #expect(try modifierAction(keyCode: 0x00, flags: .maskCommand) == nil)
    // Each side reads its own device bit, since the aggregate flag stays set while the other side is held.
    #expect(try modifierAction(keyCode: 0x36, flags: [.maskCommand, leftCommand]) == GHOSTTY_ACTION_RELEASE)
    #expect(try modifierAction(keyCode: 0x36, flags: [.maskCommand, rightCommand]) == GHOSTTY_ACTION_PRESS)
    #expect(try modifierAction(keyCode: 0x38, flags: [.maskShift, rightShift]) == GHOSTTY_ACTION_RELEASE)
    #expect(try modifierAction(keyCode: 0x38, flags: [.maskShift, leftShift, rightShift]) == GHOSTTY_ACTION_PRESS)
    #expect(try modifierAction(keyCode: 0x3C, flags: [.maskShift, leftShift]) == GHOSTTY_ACTION_RELEASE)
    // Without device bits the aggregate flag decides.
    #expect(try modifierAction(keyCode: 0x36, flags: .maskCommand) == GHOSTTY_ACTION_PRESS)
    #expect(try modifierAction(keyCode: 0x39, flags: .maskAlphaShift) == GHOSTTY_ACTION_PRESS)
    #expect(try modifierAction(keyCode: 0x39, flags: []) == GHOSTTY_ACTION_RELEASE)
  }

  @Test func hoveredSurfaceSurvivesAnOutOfOrderExit() {
    let first = makeSurfaceView()
    let second = makeSurfaceView()
    defer {
      first.closeSurface()
      second.closeSurface()
    }

    GhosttySurfaceView.LocalEventMonitor.pointerEntered(first)
    GhosttySurfaceView.LocalEventMonitor.pointerEntered(second)
    GhosttySurfaceView.LocalEventMonitor.pointerExited(first)
    #expect(GhosttySurfaceView.LocalEventMonitor.hoveredSurface === second)
    GhosttySurfaceView.LocalEventMonitor.pointerExited(second)
    #expect(GhosttySurfaceView.LocalEventMonitor.hoveredSurface == nil)
  }

  @Test func detachingDropsTheHover() {
    let surfaceView = makeSurfaceView()
    defer { surfaceView.closeSurface() }

    GhosttySurfaceView.LocalEventMonitor.pointerEntered(surfaceView)
    #expect(GhosttySurfaceView.LocalEventMonitor.hoveredSurface === surfaceView)
    // AppKit calls this with a nil window when the view detaches.
    surfaceView.viewDidMoveToWindow()

    #expect(GhosttySurfaceView.LocalEventMonitor.hoveredSurface == nil)
  }

  @Test func closeSurfaceDropsItsMonitorState() {
    let surfaceView = makeSurfaceView()
    let other = makeSurfaceView()
    defer { other.closeSurface() }
    typealias Monitor = GhosttySurfaceView.LocalEventMonitor

    Monitor.pointerEntered(surfaceView)
    Monitor.modifierPressed(by: surfaceView)
    Monitor.keyPressed(0x0C, by: surfaceView)
    Monitor.keyPressed(0x0D, by: other)
    #expect(Monitor.hoveredSurface === surfaceView)
    #expect(Monitor.isModifierHolder(surfaceView))
    surfaceView.closeSurface()

    #expect(Monitor.hoveredSurface == nil)
    #expect(!Monitor.isModifierHolder(surfaceView))
    #expect(Monitor.takeKeyHolder(for: 0x0C) == nil)
    #expect(Monitor.takeKeyHolder(for: 0x0D) === other)
  }

  @Test func keyHolderTracksTheLatestSurfaceToTakeEachKeyDown() {
    let first = makeSurfaceView()
    let second = makeSurfaceView()
    defer {
      first.closeSurface()
      second.closeSurface()
    }
    typealias Monitor = GhosttySurfaceView.LocalEventMonitor

    Monitor.keyPressed(0x11, by: first)
    Monitor.keyPressed(0x2D, by: second)
    #expect(Monitor.takeKeyHolder(for: 0x11) === first)
    #expect(Monitor.takeKeyHolder(for: 0x2D) === second)
    Monitor.keyPressed(0x11, by: second)
    #expect(Monitor.takeKeyHolder(for: 0x11) === second)
    // Taking the holder clears it.
    #expect(Monitor.takeKeyHolder(for: 0x11) == nil)
  }

  @Test func releaseKeysDropsOnlyHoldersWhoseKeyIsUp() {
    let surfaceView = makeSurfaceView()
    defer { surfaceView.closeSurface() }
    typealias Monitor = GhosttySurfaceView.LocalEventMonitor

    Monitor.keyPressed(0x00, by: surfaceView)
    Monitor.keyPressed(0x01, by: surfaceView)
    Monitor.releaseKeys { $0 == 0x00 }

    #expect(Monitor.takeKeyHolder(for: 0x00) == nil)
    #expect(Monitor.takeKeyHolder(for: 0x01) === surfaceView)
  }

  @Test func keyUpActionReleasesInTheSurfaceThatTookTheKeyDown() {
    let holder = NSObject()
    let otherSurface = NSObject()

    // AppKit never delivers a Cmd chord's key-up, so the holder always gets it, even as the responder.
    #expect(
      isRelease(keyUpAction(command: true, holder: holder, responder: otherSurface), holder: holder, consume: true))
    #expect(isRelease(keyUpAction(command: true, holder: holder, responder: holder), holder: holder, consume: true))
    // A Cmd chord no surface took (a menu shortcut) never reaches a surface.
    #expect(isPass(keyUpAction(command: true, holder: nil, responder: nil)))
    #expect(isDrop(keyUpAction(command: true, holder: nil, responder: otherSurface)))
    // After focus moved, the holder gets the release and another surface never does.
    #expect(
      isRelease(keyUpAction(command: false, holder: holder, responder: otherSurface), holder: holder, consume: true))
    // A responder that is not a surface still receives its key-up.
    #expect(isRelease(keyUpAction(command: false, holder: holder, responder: nil), holder: holder, consume: false))
    #expect(isPass(keyUpAction(command: false, holder: holder, responder: holder)))
    // No surface saw the press, so none gets a release.
    #expect(isDrop(keyUpAction(command: false, holder: nil, responder: otherSurface)))
    #expect(isPass(keyUpAction(command: false, holder: nil, responder: nil)))
  }

  @Test func mouseUpClearsTheForwardedPressNumberOnlyOnItsMatchingRelease() throws {
    let surfaceView = makeSurfaceView()
    defer { surfaceView.closeSurface() }

    surfaceView.mouseDown(with: try mouseEvent(.leftMouseDown, eventNumber: 5))
    #expect(surfaceView.forwardedLeftPressNumber == 5)
    surfaceView.mouseUp(with: try mouseEvent(.leftMouseUp, eventNumber: 5))
    #expect(surfaceView.forwardedLeftPressNumber == nil)
    // An unmatched release keeps the press pending for its real release.
    surfaceView.mouseDown(with: try mouseEvent(.leftMouseDown, eventNumber: 7))
    surfaceView.mouseUp(with: try mouseEvent(.leftMouseUp, eventNumber: 8))
    #expect(surfaceView.forwardedLeftPressNumber == 7)
    surfaceView.mouseUp(with: try mouseEvent(.leftMouseUp, eventNumber: 7))
    #expect(surfaceView.forwardedLeftPressNumber == nil)
    // A release with no forwarded press leaves nothing pending.
    surfaceView.mouseUp(with: try mouseEvent(.leftMouseUp, eventNumber: 9))
    #expect(surfaceView.forwardedLeftPressNumber == nil)
  }

  @Test func closeSurfaceDropsAPendingLeftPress() throws {
    let surfaceView = makeSurfaceView()

    surfaceView.mouseDown(with: try mouseEvent(.leftMouseDown, eventNumber: 11))
    surfaceView.closeSurface()

    #expect(surfaceView.forwardedLeftPressNumber == nil)
  }

  @Test(arguments: [
    (UInt16(0x38), NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK, CGEventFlags.maskShift),
    (UInt16(0x3C), NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK, CGEventFlags.maskShift),
    (UInt16(0x3B), NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK, CGEventFlags.maskControl),
    (UInt16(0x3E), NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK, CGEventFlags.maskControl),
    (UInt16(0x3A), NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK, CGEventFlags.maskAlternate),
    (UInt16(0x3D), NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK, CGEventFlags.maskAlternate),
    (UInt16(0x37), NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK, CGEventFlags.maskCommand),
    (UInt16(0x36), NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK, CGEventFlags.maskCommand),
  ])
  func modifierActionReadsEachKeysOwnSide(
    keyCode: UInt16,
    side: Int32,
    otherSide: Int32,
    flag: CGEventFlags
  ) throws {
    let own = CGEventFlags(rawValue: UInt64(side))
    let other = CGEventFlags(rawValue: UInt64(otherSide))

    #expect(try modifierAction(keyCode: keyCode, flags: [flag, own]) == GHOSTTY_ACTION_PRESS)
    #expect(try modifierAction(keyCode: keyCode, flags: [flag, other]) == GHOSTTY_ACTION_RELEASE)
    #expect(try modifierAction(keyCode: keyCode, flags: []) == GHOSTTY_ACTION_RELEASE)
  }

  private typealias KeyUpAction = GhosttySurfaceView.LocalEventMonitor.KeyUpAction<NSObject>

  private func keyUpAction(command: Bool, holder: NSObject?, responder: NSObject?) -> KeyUpAction {
    GhosttySurfaceView.LocalEventMonitor.keyUpAction(
      isCommandChord: command, holder: holder, responderSurface: responder)
  }

  private func isRelease(_ action: KeyUpAction, holder: NSObject, consume: Bool) -> Bool {
    guard case .release(let surface, let consumes) = action else { return false }
    return surface === holder && consumes == consume
  }

  private func isPass(_ action: KeyUpAction) -> Bool {
    guard case .pass = action else { return false }
    return true
  }

  private func isDrop(_ action: KeyUpAction) -> Bool {
    guard case .drop = action else { return false }
    return true
  }

  private func makeSurfaceView() -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  private func targets(
    hovered: NSObject?,
    holders: [NSObject],
    isRelease: Bool,
    keyResponder: NSObject?
  ) -> [NSObject] {
    GhosttySurfaceView.LocalEventMonitor.flagsChangedTargets(
      hovered: hovered,
      modifierHolders: holders,
      isRelease: isRelease,
      keyResponder: keyResponder
    )
  }

  private func modifierAction(keyCode: CGKeyCode, flags: CGEventFlags) throws -> ghostty_input_action_e? {
    let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
    cgEvent.type = .flagsChanged
    cgEvent.flags = flags
    return GhosttySurfaceView.modifierAction(for: try #require(NSEvent(cgEvent: cgEvent)))
  }

  private func mouseEvent(_ type: NSEvent.EventType, eventNumber: Int) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: 1
      )
    )
  }
}
