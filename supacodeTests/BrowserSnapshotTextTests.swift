import Testing

@testable import supacode

struct BrowserSnapshotTextTests {
  private static let form = """
    - generic [ref=e1]:
      - heading "Sign In" [level=1] [ref=e2]
      - generic [ref=e3]:
        - generic [ref=e4]:
          - text: Email
          - textbox "Email" [ref=e5]:
            - /placeholder: you@example.com
        - generic [ref=e8]:
          - checkbox "Remember me" [ref=e9]
          - text: Remember me
        - combobox "Plan" [ref=e11]:
          - option "Free" [selected]
          - option "Pro"
        - button "Sign in" [ref=e12]
      - status
      - navigation "Main" [ref=e30]:
        - link "Settings" [ref=e31] [cursor=pointer]:
          - /url: second.html
    """

  @Test func parseReadsRoleRefAndIndent() {
    let lines = BrowserSnapshotText.parse(Self.form)
    #expect(lines[0] == .init(indent: 0, content: "generic [ref=e1]:", role: "generic", ref: "e1"))
    #expect(lines[1].role == "heading")
    #expect(lines[1].ref == "e2")
    #expect(lines[4] == .init(indent: 6, content: "text: Email", role: "text", ref: nil))
    #expect(lines[6] == .init(indent: 8, content: "/placeholder: you@example.com", role: nil, ref: nil))
    #expect(lines.last { $0.ref == "e31" }?.hasPointerCursor == true)
    #expect(BrowserSnapshotText.render(lines) == Self.form)
  }

  @Test func parseIgnoresRefLookalikesInsideNamesAndValues() {
    let lines = BrowserSnapshotText.parse(
      """
      - button "Go [ref=e99]" [ref=e3]
      - paragraph [ref=e4]: see [ref=e98]
      - text: plain [ref=e97]
      - 'link "it''s: here" [ref=e5]':
      - button "say \\"hi\\" [ref=e96]" [disabled] [ref=e6]
      """)
    #expect(lines.map(\.ref) == ["e3", "e4", nil, "e5", "e6"])
    #expect(lines.map(\.role) == ["button", "paragraph", "text", "link", "button"])
  }

  @Test func interactiveKeepsControlsAndTheirOwnLines() {
    #expect(
      BrowserSnapshotText.interactive(Self.form) == """
        - textbox "Email" [ref=e5]:
          - /placeholder: you@example.com
        - checkbox "Remember me" [ref=e9]
        - combobox "Plan" [ref=e11]:
          - option "Free" [selected]
          - option "Pro"
        - button "Sign in" [ref=e12]
        - link "Settings" [ref=e31] [cursor=pointer]
        """)
  }

  @Test func interactiveKeepsClickableElementsWithoutAnInteractiveRole() {
    let text = """
      - generic [ref=e1]:
        - generic "Card" [ref=e2] [cursor=pointer]:
          - text: Open the card
          - button "Close" [ref=e3]
      """
    #expect(
      BrowserSnapshotText.interactive(text) == """
        - generic "Card" [ref=e2] [cursor=pointer]:
          - text: Open the card
          - button "Close" [ref=e3]
        """)
  }

  @Test func scopedReturnsTheSubtreeAtItsOwnIndent() {
    #expect(
      BrowserSnapshotText.scoped(Self.form, to: "e8") == """
        - generic [ref=e8]:
          - checkbox "Remember me" [ref=e9]
          - text: Remember me
        """)
    #expect(BrowserSnapshotText.scoped(Self.form, to: "e12") == "- button \"Sign in\" [ref=e12]")
    #expect(BrowserSnapshotText.scoped(Self.form, to: "e77") == nil)
  }

  @Test func cappedCutsWholeLinesAndSaysHowManyAreMissing() {
    let text = (1...10).map { "- button \"Row \($0)\" [ref=e\($0)]" }.joined(separator: "\n")
    let capped = BrowserSnapshotText.capped(text, maxBytes: 80, hint: "Narrow it.")
    #expect(
      capped == """
        - button "Row 1" [ref=e1]
        - button "Row 2" [ref=e2]
        - button "Row 3" [ref=e3]
        ... 7 more lines not shown. Narrow it.
        """)
    #expect(BrowserSnapshotText.capped(text, maxBytes: 10_000, hint: "Narrow it.") == text)
  }

  @Test func deltaReportsChangedAddedAndRemovedElements() {
    let after = """
      - generic [ref=e1]:
        - heading "Sign In" [level=1] [ref=e2]
        - generic [ref=e3]:
          - generic [ref=e4]:
            - text: Email
            - textbox "Email" [ref=e5]:
              - /placeholder: you@example.com
              - text: ada@example.com
          - generic [ref=e8]:
            - checkbox "Remember me" [checked] [ref=e9]
            - text: Remember me
          - combobox "Plan" [ref=e11]:
            - option "Free"
            - option "Pro" [selected]
          - button "Sign in" [ref=e12]
        - status [ref=e21]: Welcome ada@example.com
        - dialog "Confirm" [ref=e40]:
          - button "OK" [ref=e41]
      """
    let delta = BrowserSnapshotDelta(from: Self.form, to: after)
    #expect(
      delta.rendered(maxLines: 30) == """
        changed:
        - textbox "Email" [ref=e5]:
          - /placeholder: you@example.com
          - text: ada@example.com
        - checkbox "Remember me" [checked] [ref=e9]
        - combobox "Plan" [ref=e11]:
          - option "Free"
          - option "Pro" [selected]
        added:
        - status [ref=e21]: Welcome ada@example.com
        - dialog "Confirm" [ref=e40]:
          - button "OK" [ref=e41]
        removed:
        - status
        - navigation "Main" [ref=e30]
        """)
  }

  @Test func deltaNamesAParentWhoseChildrenMovedOrChangedOrder() {
    let before = """
      - list "Letters" [ref=e1]:
        - listitem "A" [ref=e2]
        - listitem "B" [ref=e3]
      - list "Other" [ref=e4]:
        - listitem "C" [ref=e5]
      """
    let reordered = """
      - list "Letters" [ref=e1]:
        - listitem "B" [ref=e3]
        - listitem "A" [ref=e2]
      - list "Other" [ref=e4]:
        - listitem "C" [ref=e5]
      """
    #expect(
      BrowserSnapshotDelta(from: before, to: reordered).rendered(maxLines: 30) == """
        rearranged:
        - list "Letters" [ref=e1]
        """)

    let moved = """
      - list "Letters" [ref=e1]:
        - listitem "A" [ref=e2]
      - list "Other" [ref=e4]:
        - listitem "C" [ref=e5]
        - listitem "B" [ref=e3]
      """
    #expect(
      BrowserSnapshotDelta(from: before, to: moved).rendered(maxLines: 30) == """
        rearranged:
        - list "Letters" [ref=e1]
        - list "Other" [ref=e4]
        """)

    let grown = before + "\n  - listitem \"D\" [ref=e6]"
    #expect(BrowserSnapshotDelta(from: before, to: grown).rearranged.isEmpty)
  }

  @Test func deltaOfIdenticalSnapshotsIsEmpty() {
    let delta = BrowserSnapshotDelta(from: Self.form, to: Self.form)
    #expect(delta.isEmpty)
    #expect(delta.rendered(maxLines: 30) == "no visible change")
  }

  @Test func deltaIsCutAtTheLineLimit() {
    let before = "- list [ref=e1]"
    let after = (["- list [ref=e1]:"] + (2...9).map { "  - button \"Item \($0)\" [ref=e\($0)]" }).joined(
      separator: "\n")
    let rendered = BrowserSnapshotDelta(from: before, to: after).rendered(maxLines: 3)
    #expect(
      rendered == """
        added:
        - button "Item 2" [ref=e2]
        - button "Item 3" [ref=e3]
        - button "Item 4" [ref=e4]
        ... 5 more changed lines. Run `snapshot` for the page.
        """)
  }
}
