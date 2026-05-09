import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RepositoryColorTests {
  @Test func parseIsCaseInsensitive() {
    #expect(RepositoryColor.parse("RED") == .red)
    #expect(RepositoryColor.parse("Blue") == .blue)
  }

  @Test func predefinedOrderingIsStable() {
    #expect(
      RepositoryColor.predefined == [.red, .orange, .yellow, .green, .teal, .blue, .purple]
    )
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

  @Test(
    arguments: [
      (RepositoryColor.red, "red"),
      (.orange, "orange"),
      (.yellow, "yellow"),
      (.green, "green"),
      (.teal, "teal"),
      (.blue, "blue"),
      (.purple, "purple"),
      (.custom("#A1B2C3"), "#A1B2C3"),
    ]
  )
  func codableRoundTripsAllCases(color: RepositoryColor, rawValue: String) throws {
    let encoded = try JSONEncoder().encode(color)
    #expect(String(bytes: encoded, encoding: .utf8) == "\"\(rawValue)\"")
    let decoded = try JSONDecoder().decode(RepositoryColor.self, from: encoded)
    #expect(decoded == color)
  }

  /// `ScriptDefinition.tintColor` predates the `RepositoryColor` move; ensure
  /// a settings file persisted before the move still decodes the lowercase
  /// rawValue without a migration shim.
  @Test func scriptDefinitionDecodesLegacyTintColorRawValue() throws {
    let id = UUID()
    let json = #"""
      {"id":"\#(id.uuidString)","kind":"custom","name":"Lint","command":"make lint","tintColor":"green"}
      """#
    let decoded = try JSONDecoder().decode(ScriptDefinition.self, from: Data(json.utf8))
    #expect(decoded.tintColor == .green)
  }
}
