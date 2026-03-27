import AppKit
import Foundation
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

  @Test func keyboardLayoutChangeSuppressionSuppressesMatchingKeyUpAndModifierRelease() {
    var suppression = GhosttySurfaceView.KeyboardLayoutChangeSuppression(
      keyCode: 49,
      modifierFlags: [.control, .capsLock],
      timestamp: 10
    )

    let suppressedKeyUp = suppression.suppressKeyUp(keyCode: 49, timestamp: 10.1)
    #expect(suppressedKeyUp)
    #expect(suppression.keyUpKeyCode == nil)
    let suppressedModifierRelease = suppression.suppressFlagsChanged(
      modifierFlags: [],
      timestamp: 10.2
    )
    #expect(suppressedModifierRelease)
    #expect(suppression.remainingModifiers.isEmpty)
    #expect(!suppression.isActive)
  }

  @Test func keyboardLayoutChangeSuppressionExpiresIfReleaseNeverArrives() {
    var suppression = GhosttySurfaceView.KeyboardLayoutChangeSuppression(
      keyCode: 49,
      modifierFlags: [.control],
      timestamp: 10
    )

    let suppressedKeyUp = suppression.suppressKeyUp(keyCode: 49, timestamp: 11.1)
    #expect(!suppressedKeyUp)
    #expect(!suppression.isActive)
  }
}
