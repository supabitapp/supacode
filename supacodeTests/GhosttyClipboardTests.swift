import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct GhosttyClipboardTests {
  @Test func itemCopiesExactlyLenBytesIncludingEmbeddedNul() {
    let bytes: [CChar] = [0x61, 0x00, 0x62, 0x63]
    let item = "text/plain".withCString { mime in
      bytes.withUnsafeBufferPointer { buffer in
        GhosttyClipboard.Item(ghostty_clipboard_content_s(mime: mime, data: buffer.baseAddress, len: 3))
      }
    }

    #expect(item == GhosttyClipboard.Item(mime: "text/plain", data: Data([0x61, 0x00, 0x62])))
  }

  @Test func itemWithoutDataIsEmpty() {
    let item = "image/png".withCString { mime in
      GhosttyClipboard.Item(ghostty_clipboard_content_s(mime: mime, data: nil, len: 0))
    }

    #expect(item == GhosttyClipboard.Item(mime: "image/png", data: Data()))
  }

  // An OSC 52 write with a stray byte must still land, repaired, instead of emptying the clipboard.
  @Test func textRepairsInvalidUTF8() {
    #expect(GhosttyClipboard.text(from: Data([0x61, 0xC3, 0x28])) == "a\u{FFFD}(")
  }

  @Test func requestsPlainTextOnlyForTheTextMime() {
    #expect(GhosttyClipboard.requestsPlainText(["image/png", "text/plain"]))
    #expect(!GhosttyClipboard.requestsPlainText(["image/png"]))
    #expect(!GhosttyClipboard.requestsPlainText([]))
  }

  @Test func readPlanIsUnavailableWithoutTextOrListing() {
    let plan = GhosttyClipboard.readPlan(wantsText: true, list: false, pasteboardText: nil)
    #expect(plan == GhosttyClipboard.ReadPlan(result: GHOSTTY_CLIPBOARD_READ_UNAVAILABLE, text: nil, available: []))

    let unrequested = GhosttyClipboard.readPlan(wantsText: false, list: false, pasteboardText: "hello")
    #expect(unrequested.result == GHOSTTY_CLIPBOARD_READ_UNAVAILABLE)
  }

  @Test func readPlanServesRequestedText() {
    let plan = GhosttyClipboard.readPlan(wantsText: true, list: false, pasteboardText: "hello")
    #expect(plan == GhosttyClipboard.ReadPlan(result: GHOSTTY_CLIPBOARD_READ_STARTED, text: "hello", available: []))
  }

  @Test func readPlanListsTextOnlyWhenPresent() {
    let listed = GhosttyClipboard.readPlan(wantsText: false, list: true, pasteboardText: "hello")
    #expect(
      listed == GhosttyClipboard.ReadPlan(result: GHOSTTY_CLIPBOARD_READ_STARTED, text: nil, available: ["text/plain"]))

    let empty = GhosttyClipboard.readPlan(wantsText: false, list: true, pasteboardText: nil)
    #expect(empty == GhosttyClipboard.ReadPlan(result: GHOSTTY_CLIPBOARD_READ_STARTED, text: nil, available: []))
  }

  @Test func confirmationDeniesKittyRequestsOnly() {
    #expect(GhosttyClipboard.approvesConfirmation(for: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
    #expect(GhosttyClipboard.approvesConfirmation(for: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ))
    #expect(GhosttyClipboard.approvesConfirmation(for: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE))
    #expect(!GhosttyClipboard.approvesConfirmation(for: GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ))
    #expect(!GhosttyClipboard.approvesConfirmation(for: GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE))
  }

  @Test func plainTextPicksTheTextRepresentation() {
    let items = [
      GhosttyClipboard.Item(mime: "image/png", data: Data([0x89, 0x50])),
      GhosttyClipboard.Item(mime: "text/plain", data: Data("hi".utf8)),
    ]

    #expect(GhosttyClipboard.plainText(in: items) == "hi")
    #expect(GhosttyClipboard.plainText(in: [items[0]]) == nil)
  }

  // A Kitty write carrying a PNG must keep its bytes, and text aliases must land on the string type.
  @Test func pasteboardWritesKeepBinaryAndCollapseTextAliases() {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let writes = GhosttyClipboard.pasteboardWrites([
      GhosttyClipboard.Item(mime: "UTF8_STRING", data: Data("hi".utf8)),
      GhosttyClipboard.Item(mime: "text/plain", data: Data("dup".utf8)),
      GhosttyClipboard.Item(mime: "image/png", data: png),
    ])

    #expect(writes.map(\.type) == [.string, .png])
    #expect(writes.map(\.value) == [.string("hi"), .data(png)])
  }

  @Test func pasteboardWritesSkipTextOutsideTheUTF8Aliases() {
    let writes = GhosttyClipboard.pasteboardWrites([
      GhosttyClipboard.Item(mime: "text/plain;charset=utf-16", data: Data([0xFF, 0xFE, 0x68, 0x00]))
    ])

    #expect(writes.isEmpty)
  }

  @Test func pasteboardWritesKeepRichTextTypes() {
    let html = Data("<b>hi</b>".utf8)
    let writes = GhosttyClipboard.pasteboardWrites([GhosttyClipboard.Item(mime: "text/html", data: html)])

    #expect(writes.map(\.type) == [.html])
    #expect(writes.map(\.value) == [.data(html)])
  }
}
