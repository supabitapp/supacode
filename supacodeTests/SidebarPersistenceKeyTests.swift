import Dependencies
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct SidebarPersistenceKeyTests {
  @Test func highlightRelevantDefaultsOn() {
    // First-launch discoverability contract for the View-menu toggle: the
    // Pinned and Active sections must be visible by default so users see
    // the feature without opening the menu.
    @Shared(.sidebarHighlightRelevant) var enabled
    #expect(enabled == true)
  }

  @Test func highlightSectionsDefaultExpanded() {
    // Same first-launch contract for the per-section collapse state. A
    // future flip from `true` to `false` would silently regress the
    // surfacing UX, so lock both defaults here.
    @Shared(.sidebarHighlightPinnedExpanded) var pinnedExpanded
    @Shared(.sidebarHighlightActiveExpanded) var activeExpanded
    #expect(pinnedExpanded == true)
    #expect(activeExpanded == true)
  }

  @Test func corruptFileIsRenamedBeforeFallback() async throws {
    // Write the corrupt bytes to an isolated temp directory so the
    // test never touches the user's real `~/.supacode/sidebar.json`.
    // The live `\.settingsFileStorage` is used because we want to
    // exercise the real `moveItem` rename path; `\.sidebarFileURL`
    // is overridden to point at our temp file so the SharedKey
    // reads/writes there exclusively.
    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory
      .appending(path: "SidebarPersistenceKeyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: sandbox)
    }
    let sidebarURL = sandbox.appending(path: "sidebar.json", directoryHint: .notDirectory)
    try Data("this-is-not-json".utf8).write(to: sidebarURL)

    await withDependencies {
      $0.settingsFileStorage = SettingsFileStorageKey.liveValue
      $0.sidebarFileURL = sidebarURL
    } operation: {
      // Touching `@Shared(.sidebar)` triggers `SidebarKey.load`,
      // which on decode failure must rename the corrupt file.
      @Shared(.sidebar) var sidebar
      _ = sidebar
    }

    #expect(!fileManager.fileExists(atPath: sidebarURL.path(percentEncoded: false)))
    let entries = try fileManager.contentsOfDirectory(
      at: sandbox, includingPropertiesForKeys: nil
    )
    let renamed = entries.first { $0.lastPathComponent.hasPrefix("sidebar.json.corrupt-") }
    #expect(renamed != nil)
  }
}
