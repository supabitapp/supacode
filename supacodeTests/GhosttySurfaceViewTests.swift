import AppKit
import Foundation
import GhosttyKit
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

  // backgroundTintColor(_:) is the pure color-computation kernel for per-surface
  // OSC 11 tinting. It converts an (r, g, b, opacity) tuple into a CGColor
  // for the surface's CALayer.backgroundColor, or nil when no tint should be shown.
  //
  // Kind-routing is done upstream in GhosttySurfaceBridge: OSC 10 / OSC 12 /
  // palette writes go to separate state fields and never reach the background triple.
  // This function only receives background state, so it guards only nil r/g/b.

  // backgroundTintOpacity(_:) selects the CALayer alpha for the tint based on
  // whether the window is running with blur active. The 0.3 / 1.0 split exists
  // because the tint sits on top of the blurred backdrop rather than being part
  // of it: at 0.3 the blur is prominent, at 1.0 the colour is prominent. There
  // is nothing useful in between when no blur is present — a mid-range alpha over
  // a flat opaque background just produces a washed-out colour.
  //
  // The concrete value 0.3 is not user-configurable in this release. A settings
  // control is a follow-up once the maintainer has validated the default feels right
  // across different themes and wallpapers.

  @Test func backgroundTintOpacityOpaqueOnBlurOff() {
    // Opaque toggle wins regardless of blur state.
    #expect(
      abs(
        GhosttySurfaceView.backgroundTintOpacity(isBackgroundOpaque: true, isBackgroundBlurEnabled: false) - 1.0
      ) < 0.001
    )
  }

  @Test func backgroundTintOpacityOpaqueOnBlurOn() {
    // Opaque toggle wins even when blur is configured.
    #expect(
      abs(
        GhosttySurfaceView.backgroundTintOpacity(isBackgroundOpaque: true, isBackgroundBlurEnabled: true) - 1.0
      ) < 0.001
    )
  }

  @Test func backgroundTintOpacityOpaqueOffBlurOn() {
    // Blur active and opaque off: tint is semi-transparent so blur shows through.
    #expect(
      abs(
        GhosttySurfaceView.backgroundTintOpacity(isBackgroundOpaque: false, isBackgroundBlurEnabled: true) - 0.3
      ) < 0.001
    )
  }

  @Test func backgroundTintOpacityOpaqueOffBlurOff() {
    // No blur, no opaque override: tint is fully opaque against the flat background.
    #expect(
      abs(
        GhosttySurfaceView.backgroundTintOpacity(isBackgroundOpaque: false, isBackgroundBlurEnabled: false) - 1.0
      ) < 0.001
    )
  }

  @Test func backgroundTintColorReturnsNilWhenRedIsAbsent() {
    // The bridge writes red/green/blue together, but each is independently optional.
    // Guard against a partially-set state producing a nonsense color.
    #expect(GhosttySurfaceView.backgroundTintColor(red: nil, green: 0, blue: 0, opacity: 1.0) == nil)
  }

  @Test func backgroundTintColorReturnsNilWhenGreenIsAbsent() {
    #expect(GhosttySurfaceView.backgroundTintColor(red: 0, green: nil, blue: 0, opacity: 1.0) == nil)
  }

  @Test func backgroundTintColorReturnsNilWhenBlueIsAbsent() {
    #expect(GhosttySurfaceView.backgroundTintColor(red: 0, green: 0, blue: nil, opacity: 1.0) == nil)
  }

  @Test func backgroundTintColorConvertsRGBBytesToSRGBComponents() {
    // OSC 11 delivers color as 8-bit RGB (0–255 per channel). Verify the
    // conversion to normalised sRGB (0.0–1.0) is exact to floating-point limits.
    // Using 26/42/58 so each channel has a distinct non-trivial value.
    let color = GhosttySurfaceView.backgroundTintColor(red: 26, green: 42, blue: 58, opacity: 1.0)
    let nsColor = color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
    #expect(nsColor != nil)
    #expect(abs((nsColor?.redComponent ?? 0) - CGFloat(26) / 255) < 0.001)
    #expect(abs((nsColor?.greenComponent ?? 0) - CGFloat(42) / 255) < 0.001)
    #expect(abs((nsColor?.blueComponent ?? 0) - CGFloat(58) / 255) < 0.001)
    #expect(abs((nsColor?.alphaComponent ?? 0) - 1.0) < 0.001)
  }

  @Test func backgroundTintColorAppliesOpacity() {
    let color = GhosttySurfaceView.backgroundTintColor(red: 255, green: 255, blue: 255, opacity: 0.9)
    let nsColor = color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
    #expect(abs((nsColor?.alphaComponent ?? 0) - 0.9) < 0.001)
  }

  @Test func backgroundTintColorIsFullyOpaqueAtOpacityOne() {
    let color = GhosttySurfaceView.backgroundTintColor(red: 0, green: 0, blue: 0, opacity: 1.0)
    let nsColor = color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
    #expect(abs((nsColor?.alphaComponent ?? 0) - 1.0) < 0.001)
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
