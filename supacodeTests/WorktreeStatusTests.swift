import Foundation
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeStatusTests {
  private let repositoryID: Repository.ID = "/tmp/repo/"

  private func populatedSidebar() -> SidebarState {
    var sidebar = SidebarState()
    sidebar.sections[repositoryID] = .init(
      buckets: [
        .pinned: .init(),
        .unpinned: .init(),
        .archived: .init(),
      ]
    )
    sidebar.insert(worktree: "/tmp/repo", in: repositoryID, bucket: .pinned)
    sidebar.insert(worktree: "/tmp/repo/pinned", in: repositoryID, bucket: .pinned)
    sidebar.insert(worktree: "/tmp/repo/unpinned", in: repositoryID, bucket: .unpinned)
    sidebar.insert(
      worktree: "/tmp/repo/archived",
      in: repositoryID,
      bucket: .archived,
      item: .init(archivedAt: Date(timeIntervalSince1970: 1))
    )
    return sidebar
  }

  // MARK: - Classification.

  @Test func statusFlattensEveryBucket() {
    let sidebar = populatedSidebar()

    #expect(sidebar.status(of: "/tmp/repo/pinned", in: repositoryID, isMain: false) == .pinned)
    #expect(sidebar.status(of: "/tmp/repo/unpinned", in: repositoryID, isMain: false) == .unpinned)
    #expect(sidebar.status(of: "/tmp/repo/archived", in: repositoryID, isMain: false) == .archived)
  }

  @Test func mainWinsOverItsBucketButNotOverArchiving() {
    let sidebar = populatedSidebar()

    // The default workspace is auto-pinned, and it can also be archived.
    #expect(sidebar.status(of: "/tmp/repo", in: repositoryID, isMain: true) == .main)
    #expect(sidebar.status(of: "/tmp/repo/archived", in: repositoryID, isMain: true) == .archived)
  }

  @Test func unbucketedAndUnknownSectionsReadAsUnpinned() {
    let sidebar = populatedSidebar()

    // Newly discovered worktrees render into the unpinned bucket.
    #expect(sidebar.status(of: "/tmp/repo/fresh", in: repositoryID, isMain: false) == .unpinned)
    #expect(sidebar.status(of: "/tmp/other/wt", in: "/tmp/other/", isMain: false) == .unpinned)
    #expect(sidebar.isArchived("/tmp/other/wt", in: "/tmp/other/") == false)
  }

  // MARK: - Wire payload.

  @Test func listFieldsEncodeIDsAndMarkFocus() {
    let fields = WorktreeStatusQueryResponse.listFields(
      worktreeID: "/tmp/repo/default workspace",
      status: .main,
      isFocused: true
    )

    #expect(fields["id"] == "%2Ftmp%2Frepo%2Fdefault%20workspace")
    #expect(fields["status"] == "main")
    #expect(fields["focused"] == "1")
  }

  @Test func listFieldsOmitFocusForUnselectedArchivedWorktrees() {
    let fields = WorktreeStatusQueryResponse.listFields(
      worktreeID: "/tmp/repo/old",
      status: .archived,
      isFocused: false
    )

    #expect(fields["status"] == "archived")
    #expect(fields["focused"] == nil)
  }

  @Test func statusFieldsReportArchivedAndFocusExplicitly() {
    let archived = WorktreeStatusQueryResponse.statusFields(status: .archived, isFocused: false)
    #expect(archived["status"] == "archived")
    #expect(archived["archived"] == "true")
    #expect(archived["focused"] == "false")

    let pinned = WorktreeStatusQueryResponse.statusFields(status: .pinned, isFocused: true)
    #expect(pinned["status"] == "pinned")
    #expect(pinned["archived"] == "false")
    #expect(pinned["focused"] == "true")
  }

  @Test func everyStatusRoundTripsThroughItsRawValue() {
    for status in SidebarState.WorktreeStatus.allCases {
      #expect(SidebarState.WorktreeStatus(rawValue: status.rawValue) == status)
    }
    #expect(
      SidebarState.WorktreeStatus.allCases.map(\.rawValue) == ["main", "pinned", "unpinned", "archived"]
    )
  }
}
