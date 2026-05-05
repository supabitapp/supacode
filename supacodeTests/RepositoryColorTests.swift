import Foundation
import Testing

@testable import supacode

@MainActor
struct RepositoryColorTests {
  @Test func parseAcceptsPredefinedNamesCaseInsensitively() {
    #expect(RepositoryColor.parse("red") == .red)
    #expect(RepositoryColor.parse("RED") == .red)
    #expect(RepositoryColor.parse("Blue") == .blue)
    #expect(RepositoryColor.parse("purple") == .purple)
  }

  @Test func parseAcceptsHexAndNormalizesCase() {
    #expect(RepositoryColor.parse("#A1B2C3") == .custom("#A1B2C3"))
    #expect(RepositoryColor.parse("#a1b2c3") == .custom("#A1B2C3"))
  }

  @Test func parseRejectsMalformedInput() {
    #expect(RepositoryColor.parse("not-a-color") == nil)
    #expect(RepositoryColor.parse("#abc") == nil)
    #expect(RepositoryColor.parse("#GGGGGG") == nil)
    #expect(RepositoryColor.parse("") == nil)
  }

  @Test func decoderThrowsOnGarbageInput() {
    let json = Data("\"not-a-color\"".utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(RepositoryColor.self, from: json)
    }
  }

  @Test func encoderEmitsCanonicalRawValue() throws {
    let predefined = try JSONEncoder().encode(RepositoryColor.green)
    #expect(String(bytes: predefined, encoding: .utf8) == "\"green\"")

    let custom = try JSONEncoder().encode(RepositoryColor.custom("#A1B2C3"))
    #expect(String(bytes: custom, encoding: .utf8) == "\"#A1B2C3\"")
  }
}
