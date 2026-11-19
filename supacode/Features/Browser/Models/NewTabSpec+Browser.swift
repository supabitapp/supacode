import Foundation

nonisolated extension NewTabSpec {
  static func browser(
    url: URL?,
    geometry: ContentGeometry,
    select: Bool = true,
    tabID: TabID? = nil,
    contentID: ContentID? = nil
  ) -> NewTabSpec {
    NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: "New Tab",
      content: .browser(BrowserContentState(url: url)),
      geometry: geometry,
      select: select
    )
  }
}
