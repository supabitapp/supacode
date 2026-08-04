import Foundation
import Testing

@testable import supacode

@MainActor
struct GitStatusParserTests {
  // MARK: - Porcelain v2 record builders

  /// An ordinary (`1`) record: 8 fixed fields then the path.
  private static func ordinary(_ codes: String, _ path: String) -> String {
    "1 \(codes) N... 100644 100644 100644 1111111 2222222 \(path)"
  }

  /// A rename/copy (`2`) record; the original path is a separate token.
  private static func renamed(_ codes: String, from origin: String, to path: String) -> String {
    "2 \(codes) N... 100644 100644 100644 1111111 2222222 R100 \(path)\0\(origin)"
  }

  /// An unmerged (`u`) record: 10 fixed fields then the path.
  private static func unmerged(_ codes: String, _ path: String) -> String {
    "u \(codes) N... 100644 100644 100644 100644 1111111 2222222 3333333 \(path)"
  }

  /// Joins records into the NUL-delimited, NUL-terminated stream git emits.
  private static func stream(_ records: [String]) -> String {
    records.map { $0 + "\0" }.joined()
  }

  // MARK: - Axis parsing

  @Test func emptyOutputIsCleanSnapshot() {
    #expect(GitStatusSnapshot.parse(porcelainV2: "") == .empty)
  }

  @Test func unstagedModificationSetsWorktreeAxisOnly() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.worktree == .modified)
    #expect(snapshot.statuses["a.txt"]?.index == nil)
  }

  @Test func stagedModificationSetsIndexAxisOnly() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("M.", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.index == .modified)
    #expect(snapshot.statuses["a.txt"]?.worktree == nil)
  }

  @Test func stagedThenEditedSetsBothAxes() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("MM", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.index == .modified)
    #expect(snapshot.statuses["a.txt"]?.worktree == .modified)
  }

  @Test func stagedAddAndDeleteMapToKinds() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary("A.", "new.txt"), Self.ordinary("D.", "gone.txt")])
    )
    #expect(snapshot.statuses["new.txt"]?.index == .added)
    #expect(snapshot.statuses["gone.txt"]?.index == .deleted)
  }

  @Test func untrackedAndIgnoredAreDistinct() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream(["? scratch.log", "! node_modules/"])
    )
    #expect(snapshot.statuses["scratch.log"]?.isUntracked == true)
    // The wholly-ignored directory is reported once, trailing slash stripped.
    #expect(snapshot.ignoredPrefixes == ["node_modules"])
    #expect(snapshot.statuses["node_modules"] == nil)
  }

  @Test func conflictSetsConflictedFlag() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.unmerged("UU", "clash.txt")]))
    #expect(snapshot.statuses["clash.txt"]?.isConflicted == true)
  }

  // MARK: - Record framing

  @Test func renameRecordConsumesItsOriginTokenWithoutDesync() {
    // A `2` record embeds a second NUL for the origin path; a following ordinary
    // record must still parse, proving the stream didn't desync.
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([
        Self.renamed("R.", from: "old.txt", to: "new.txt"),
        Self.ordinary(".M", "after.txt"),
      ])
    )
    #expect(snapshot.statuses["new.txt"]?.index == .modified)
    #expect(snapshot.statuses["after.txt"]?.worktree == .modified)
    // The origin token was consumed, not parsed as a bogus entry.
    #expect(snapshot.statuses["old.txt"] == nil)
  }

  @Test func pathWithSpacesIsPreserved() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "my notes.txt")]))
    #expect(snapshot.statuses["my notes.txt"]?.worktree == .modified)
  }

  @Test func trailingNulProducesNoPhantomEntry() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a.txt")]))
    #expect(snapshot.statuses.count == 1)
  }

  // MARK: - Ancestor rollup

  @Test func changedFileRollsUpToEachAncestorDirectory() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a/b/c.txt")]))
    #expect(snapshot.changedAncestors == ["a", "a/b"])
    #expect(!snapshot.changedAncestors.contains("a/b/c.txt"))
  }

  @Test func ignoredEntryDoesNotRollUp() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["! build/artifacts/"]))
    #expect(snapshot.changedAncestors.isEmpty)
  }

  // MARK: - Decoration resolution

  @Test func fileDecorationReflectsStateAndStagedness() {
    let snapshot = GitStatusSnapshot.parse(
      porcelainV2: Self.stream([Self.ordinary("M.", "staged.txt"), Self.ordinary(".M", "dirty.txt")])
    )
    #expect(
      snapshot.decoration(for: "staged.txt", isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: true)
    )
    #expect(
      snapshot.decoration(for: "dirty.txt", isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
  }

  @Test func bothAxesDecorateFromTheStagedSide() {
    // Staged-modified then worktree-deleted: the staged index change wins the
    // letter, and the row reads as staged.
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary("MD", "a.txt")]))
    #expect(snapshot.statuses["a.txt"]?.index == .modified)
    #expect(snapshot.statuses["a.txt"]?.worktree == .deleted)
    #expect(
      snapshot.decoration(for: "a.txt", isDirectory: false, isExpanded: false)
        == .file(state: .modified, isStaged: true)
    )
  }

  @Test func untrackedFileDecoratesAsUnstagedAdd() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["? fresh.txt"]))
    #expect(
      snapshot.decoration(for: "fresh.txt", isDirectory: false, isExpanded: false)
        == .file(state: .added, isStaged: false)
    )
  }

  @Test func conflictDecoratesAsConflicted() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.unmerged("UU", "clash.txt")]))
    #expect(
      snapshot.decoration(for: "clash.txt", isDirectory: false, isExpanded: false)
        == .file(state: .conflicted, isStaged: false)
    )
  }

  @Test func collapsedDirectoryWithChangesReadsAsModifiedButExpandedDoesNot() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a/b/c.txt")]))
    #expect(
      snapshot.decoration(for: "a", isDirectory: true, isExpanded: false)
        == .file(state: .modified, isStaged: false)
    )
    #expect(snapshot.decoration(for: "a", isDirectory: true, isExpanded: true) == nil)
  }

  @Test func ignoredPrefixDimsTheWholeSubtree() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream(["! node_modules/"]))
    #expect(snapshot.decoration(for: "node_modules", isDirectory: true, isExpanded: false) == .ignored)
    #expect(snapshot.decoration(for: "node_modules/lib/x.js", isDirectory: false, isExpanded: false) == .ignored)
    // A sibling that merely shares a name prefix is not dimmed.
    #expect(snapshot.decoration(for: "node_modules_backup", isDirectory: true, isExpanded: false) == nil)
  }

  // MARK: - Discard classification

  private static func discardKind(_ records: [String]) -> GitDiscardKind? {
    GitStatusSnapshot.parse(porcelainV2: Self.stream(records)).statuses.values.first?.discardKind
  }

  @Test func discardKindRoutesEachState() {
    #expect(Self.discardKind(["? new.txt"]) == .trash)
    #expect(Self.discardKind([Self.ordinary("A.", "staged-new.txt")]) == .trash)
    #expect(Self.discardKind([Self.ordinary(".M", "mod.txt")]) == .restore)
    #expect(Self.discardKind([Self.ordinary("MM", "both.txt")]) == .restore)
    #expect(Self.discardKind([Self.unmerged("UU", "clash.txt")]) == nil)
    // `git rm --cached` reports a staged deletion AND an untracked working copy
    // for one path; it has a committed version, so discard restores, not trashes.
    #expect(Self.discardKind([Self.ordinary("D.", "rm-cached.txt"), "? rm-cached.txt"]) == .restore)
  }

  @Test func cleanPathHasNoDecoration() {
    let snapshot = GitStatusSnapshot.parse(porcelainV2: Self.stream([Self.ordinary(".M", "a.txt")]))
    #expect(snapshot.decoration(for: "b.txt", isDirectory: false, isExpanded: false) == nil)
  }
}
