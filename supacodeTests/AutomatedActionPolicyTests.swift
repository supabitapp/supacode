import Testing

@testable import supacode

struct AutomatedActionPolicyTests {
  // MARK: - allowsBypass.

  @Test func alwaysBypassesForSocket() {
    #expect(AutomatedActionPolicy.always.allowsBypass(from: .socket) == true)
  }

  @Test func alwaysBypassesForURLScheme() {
    #expect(AutomatedActionPolicy.always.allowsBypass(from: .urlScheme) == true)
  }

  @Test func cliOnlyBypassesForSocket() {
    #expect(AutomatedActionPolicy.cliOnly.allowsBypass(from: .socket) == true)
  }

  @Test func cliOnlyDoesNotBypassForURLScheme() {
    #expect(AutomatedActionPolicy.cliOnly.allowsBypass(from: .urlScheme) == false)
  }

  @Test func deeplinksOnlyBypassesForURLScheme() {
    #expect(AutomatedActionPolicy.deeplinksOnly.allowsBypass(from: .urlScheme) == true)
  }

  @Test func deeplinksOnlyDoesNotBypassForSocket() {
    #expect(AutomatedActionPolicy.deeplinksOnly.allowsBypass(from: .socket) == false)
  }

  @Test func neverDoesNotBypassForSocket() {
    #expect(AutomatedActionPolicy.never.allowsBypass(from: .socket) == false)
  }

  @Test func neverDoesNotBypassForURLScheme() {
    #expect(AutomatedActionPolicy.never.allowsBypass(from: .urlScheme) == false)
  }
}
