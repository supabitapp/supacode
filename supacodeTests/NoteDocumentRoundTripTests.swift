import AppKit
import Foundation
import Testing

@testable import supacode

@MainActor
struct NoteDocumentRoundTripTests {
  @Test func boldAndUnderlineSurviveRoundTrip() throws {
    let manager = NSFontManager.shared
    let attributed = NSMutableAttributedString(string: "Hello world")
    let bold = manager.convert(NoteTextStyle.body.baseFont, toHaveTrait: .boldFontMask)
    attributed.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
    attributed.addAttribute(
      .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 6, length: 5))

    let document = try #require(NoteDocument.make(from: attributed, lastModified: Date()))
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(NoteDocument.self, from: data)
    let restored = decoded.attributedString()

    #expect(restored.string == "Hello world")
    let restoredFont = restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(restoredFont.map { manager.traits(of: $0).contains(.boldFontMask) } == true)
    let underline = restored.attribute(.underlineStyle, at: 6, effectiveRange: nil) as? Int
    #expect((underline ?? 0) != 0)
  }

  @Test func emptyContentProducesNilDocument() {
    #expect(NoteDocument.make(from: NSAttributedString(string: "   \n\t"), lastModified: Date()) == nil)
  }

  @Test func corruptRTFDecodesToEmptyStringWithoutCrashing() {
    let document = NoteDocument(rtf: Data("definitely not rtf".utf8), lastModified: Date())
    #expect(document.attributedString().string.isEmpty)
  }
}
