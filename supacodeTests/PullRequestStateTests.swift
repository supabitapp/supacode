import Foundation
import Testing

@testable import supacode

struct PullRequestStateTests {
  @Test func stateFoldsCaseInsensitively() {
    #expect(PullRequestState(rawValue: "MERGED") == .merged)
    #expect(PullRequestState(rawValue: "merged") == .merged)
    #expect(PullRequestState(rawValue: "OPEN") == .open)
    #expect(PullRequestState(rawValue: "opened") == .open)
    #expect(PullRequestState(rawValue: "CLOSED") == .closed)
    #expect(PullRequestState(rawValue: "closed") == .closed)
  }

  @Test func unrecognizedStateFallsBackToUnknown() {
    #expect(PullRequestState(rawValue: "locked") == .unknown("LOCKED"))
    // Casing-blind equality so responses differing only in casing are no-ops.
    #expect(PullRequestState(rawValue: "locked") == PullRequestState(rawValue: "Locked"))
    #expect(PullRequestState(rawValue: "locked").displayLabel == "LOCKED")
  }

  @Test func decodesLowercaseStateFromJSON() throws {
    let json = Data(#"{"state":"merged"}"#.utf8)
    let decoded = try JSONDecoder().decode([String: PullRequestState].self, from: json)
    #expect(decoded["state"] == .merged)
  }

  @Test func displayLabelMatchesBadgeCasing() {
    #expect(PullRequestState.open.displayLabel == "OPEN")
    #expect(PullRequestState.merged.displayLabel == "MERGED")
    #expect(PullRequestState.closed.displayLabel == "CLOSED")
  }
}
