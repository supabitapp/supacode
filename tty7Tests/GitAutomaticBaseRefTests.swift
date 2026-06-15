import Testing

@testable import tty7

struct GitAutomaticBaseRefTests {
  @Test func prefersRemoteWhenAvailable() {
    let value = GitClient.preferredBaseRef(remote: "origin/main", localHead: "main")
    #expect(value == "origin/main")
  }

  @Test func fallsBackToLocalHead() {
    let value = GitClient.preferredBaseRef(remote: nil, localHead: "main")
    #expect(value == "main")
  }

  @Test func returnsNilWhenNoRefs() {
    let value = GitClient.preferredBaseRef(remote: nil, localHead: nil)
    #expect(value == nil)
  }
}
