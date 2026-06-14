import AppKit
import Foundation
import Testing

@testable import supacode

@MainActor
struct ClipboardPasteImageTests {
  /// PNG 数据应原样透传，不做任何转换。
  @Test func pastedImagePNGDataPassesThroughPNG() {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    #expect(NSPasteboard.pastedImagePNGData(png: png, tiff: nil) == png)
  }

  /// 既没有 PNG 也没有 TIFF 时返回 nil，调用方据此回退到“无内容”。
  @Test func pastedImagePNGDataReturnsNilWhenNoImage() {
    #expect(NSPasteboard.pastedImagePNGData(png: nil, tiff: nil) == nil)
  }

  /// TIFF 数据应被转码为 PNG（以 PNG 魔数字节开头）。
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

  /// 写入临时文件后，返回的路径应真实存在、内容一致、且落在目标目录下、扩展名为 png。
  @Test func writePastedImageWritesFileAndReturnsPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "supacode-pasted-images-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
    let path = try #require(NSPasteboard.writePastedImage(payload, to: directory))

    #expect(path.hasSuffix(".png"))
    #expect(path.hasPrefix(directory.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(try Data(contentsOf: URL(filePath: path)) == payload)
  }

  /// 每次写入都生成唯一文件名，连续粘贴两张图片不会互相覆盖。
  @Test func writePastedImageProducesUniquePaths() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "supacode-pasted-images-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = Data([0x89, 0x50, 0x4E, 0x47])
    let first = try #require(NSPasteboard.writePastedImage(payload, to: directory))
    let second = try #require(NSPasteboard.writePastedImage(payload, to: directory))
    #expect(first != second)
  }

  /// 剪贴板只有图片数据时，粘贴内容应回退到落盘后的临时图片路径（经 ghostty 转义）。
  @Test func opinionatedContentsFallsBackToImagePath() throws {
    let pasteboard = NSPasteboard(name: .init("supacode.test.image.\(UUID().uuidString)"))
    pasteboard.clearContents()
    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    pasteboard.setData(payload, forType: .png)

    let contents = try #require(pasteboard.getOpinionatedStringContents())
    #expect(contents.contains("pasted-image"))
    #expect(contents.hasSuffix(".png"))
  }

  /// 文本优先于图片：同时存在文本和图片数据时返回文本，不会误把图片落盘。
  @Test func opinionatedContentsPrefersTextOverImage() {
    let pasteboard = NSPasteboard(name: .init("supacode.test.text.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    pasteboard.setString("hello world", forType: .string)

    #expect(pasteboard.getOpinionatedStringContents() == "hello world")
  }
}
