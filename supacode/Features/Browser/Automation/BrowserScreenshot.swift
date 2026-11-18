import AppKit
import WebKit

enum BrowserScreenshot {
  static func save(_ webView: WKWebView, to path: String?) async throws(BrowserAutomationError) -> String {
    let image: NSImage
    do {
      image = try await webView.takeSnapshot(configuration: nil)
    } catch {
      throw .internalFailure("The screenshot failed: \(error.localizedDescription)")
    }
    guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else {
      throw .internalFailure("The screenshot could not be encoded.")
    }
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
