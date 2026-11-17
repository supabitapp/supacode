import Foundation

nonisolated extension NewTabSpec {
  static func browser(url: URL?, geometry: ContentGeometry, select: Bool = true) -> NewTabSpec {
    NewTabSpec(
      title: "New Tab",
      content: .browser(BrowserContentState(url: url)),
      geometry: geometry,
      select: select
    )
  }
}
