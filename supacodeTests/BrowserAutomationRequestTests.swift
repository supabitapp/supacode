import Foundation
import Testing

@testable import supacode

struct BrowserAutomationRequestTests {
  @Test func decodesTheStepsTheCLISends() throws {
    let request = try BrowserAutomationRequest(
      json: """
        {"tabID":"T1","quiet":true,"steps":[
          {"verb":"fill","target":"e5","text":"ada"},
          {"verb":"wait","text":"Welcome","timeout":2.5,"hidden":false},
          {"verb":"snapshot","full":true,"scope":"e3"}
        ]}
        """)
    #expect(request.tabID == "T1")
    #expect(request.quiet)
    #expect(
      request.steps == [
        BrowserAutomationStep(verb: .fill, target: "e5", text: "ada"),
        BrowserAutomationStep(verb: .wait, text: "Welcome", hidden: false, timeout: 2.5),
        BrowserAutomationStep(verb: .snapshot, full: true, scope: "e3"),
      ])
  }

  @Test func decodesANewTabRequestWithoutSteps() throws {
    let request = try BrowserAutomationRequest(json: #"{"newTab":{"url":"localhost:3000","background":true}}"#)
    #expect(request.newTab == .init(url: "localhost:3000", background: true))
    #expect(request.steps.isEmpty)
    #expect(!request.quiet)
  }

  @Test func rejectsAnUnknownVerb() {
    #expect(throws: (any Error).self) {
      try BrowserAutomationRequest(json: #"{"steps":[{"verb":"eval"}]}"#)
    }
  }

  @Test func pageOutputIsWrappedInNonceMarkers() {
    let result = BrowserAutomationResult(lines: ["clicked button \"Save\"", "no visible change"])
    #expect(
      result.response(nonce: "ab12cd") == [
        "output": """
        --- page ab12cd ---
        clicked button "Save"
        no visible change
        --- end ab12cd ---
        """
      ])
  }

  @Test func aFailureStaysInsideThePageOutput() {
    let result = BrowserAutomationResult(lines: ["filled textbox \"Email\""], failure: "button \"Save\" is disabled.")
    #expect(
      result.response(nonce: "ab12cd") == [
        "output": """
        --- page ab12cd ---
        filled textbox "Email"
        failed: button "Save" is disabled.
        --- end ab12cd ---
        """,
        "error": "The browser command failed. The reason is in the page output.",
      ])
  }

  @Test func aRefusalAndANewTabCarryNoPageOutput() {
    #expect(BrowserAutomationResult(refusal: "No tab.").response(nonce: "x") == ["error": "No tab."])
    #expect(BrowserAutomationResult(createdTabID: "T9").response(nonce: "x") == ["id": "T9"])
  }
}
