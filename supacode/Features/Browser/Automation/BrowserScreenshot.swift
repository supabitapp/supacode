import AppKit

enum BrowserScreenshot {
  static func png(_ image: NSImage) -> Data? {
    image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
  }

  static func write(_ png: Data, to path: String?) throws(BrowserAutomationError) -> String {
    let file =
      path.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory.appending(path: "supacode-browser/\(UUID().uuidString).png")
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: file)
    } catch {
      throw .rejected("The screenshot could not be written to \(file.path(percentEncoded: false)).")
    }
    return file.path(percentEncoded: false)
  }
}
