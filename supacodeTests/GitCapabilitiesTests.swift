import Foundation
import Testing

@testable import CherryLily

struct GitCapabilitiesTests {
  @Test func parsesModernVersionAsSupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "git version 2.39.5 (Apple Git-154)") == true)
  }

  @Test func parsesExactThresholdAsSupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "git version 2.37.0") == true)
  }

  @Test func parsesOldVersionAsUnsupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "git version 2.36.9") == false)
  }

  @Test func parsesGarbageAsUnsupported() {
    #expect(GitCapabilities.parseFsmonitorSupport(fromVersionOutput: "not a version") == false)
  }
}
