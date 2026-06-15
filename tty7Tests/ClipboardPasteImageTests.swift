import AppKit
import Foundation
import Testing

@testable import tty7

@MainActor
struct ClipboardPasteImageTests {
  /// PNG data passes through unchanged, with no conversion.
  @Test func pastedImagePNGDataPassesThroughPNG() {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    #expect(NSPasteboard.pastedImagePNGData(png: png, tiff: nil) == png)
  }

  /// Returns nil when there is neither PNG nor TIFF, so the caller falls back to "no content".
  @Test func pastedImagePNGDataReturnsNilWhenNoImage() {
    #expect(NSPasteboard.pastedImagePNGData(png: nil, tiff: nil) == nil)
  }

  /// TIFF data is transcoded to PNG (output starts with the PNG magic bytes).
  @Test func pastedImagePNGDataConvertsTIFFToPNG() throws {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)

    let png = try #require(NSPasteboard.pastedImagePNGData(png: nil, tiff: tiff))
    #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
  }

  /// After writing, the returned path exists, has matching content, sits under
  /// the target directory, and ends in .png.
  @Test func writePastedImageWritesFileAndReturnsPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "tty7-pasted-images-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
    let path = try #require(NSPasteboard.writePastedImage(payload, to: directory))

    #expect(path.hasSuffix(".png"))
    #expect(path.hasPrefix(directory.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(try Data(contentsOf: URL(filePath: path)) == payload)
  }

  /// Each write gets a unique filename, so pasting two images in a row doesn't overwrite.
  @Test func writePastedImageProducesUniquePaths() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "tty7-pasted-images-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = Data([0x89, 0x50, 0x4E, 0x47])
    let first = try #require(NSPasteboard.writePastedImage(payload, to: directory))
    let second = try #require(NSPasteboard.writePastedImage(payload, to: directory))
    #expect(first != second)
  }

  /// Writing a new image also prunes files older than the threshold while keeping
  /// recent files and the just-written one, so the temp dir doesn't grow unbounded.
  @Test func writePastedImagePrunesStaleFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "tty7-pasted-images-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let stale = directory.appending(path: "pasted-image-stale.png", directoryHint: .notDirectory)
    let fresh = directory.appending(path: "pasted-image-fresh.png", directoryHint: .notDirectory)
    try Data([0x89]).write(to: stale)
    try Data([0x89]).write(to: fresh)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)],
      ofItemAtPath: stale.path(percentEncoded: false),
    )

    let newPath = try #require(NSPasteboard.writePastedImage(Data([0x89, 0x50]), to: directory))

    #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: newPath))
  }

  /// When the clipboard holds only image data, the pasted content falls back to
  /// the saved temp image path (ghostty-escaped).
  @Test func opinionatedContentsFallsBackToImagePath() throws {
    let pasteboard = NSPasteboard(name: .init("tty7.test.image.\(UUID().uuidString)"))
    pasteboard.clearContents()
    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    pasteboard.setData(payload, forType: .png)

    let contents = try #require(pasteboard.getOpinionatedStringContents())
    #expect(contents.contains("pasted-image"))
    #expect(contents.hasSuffix(".png"))
  }

  /// Text takes precedence over image: with both present, return the text and don't write the image to disk.
  @Test func opinionatedContentsPrefersTextOverImage() {
    let pasteboard = NSPasteboard(name: .init("tty7.test.text.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    pasteboard.setString("hello world", forType: .string)

    #expect(pasteboard.getOpinionatedStringContents() == "hello world")
  }
}
