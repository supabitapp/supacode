import SupacodeSettingsShared
import SwiftUI

struct TerminalTabsView: View {
  @Bindable var manager: TerminalTabManager
  let closeTab: (TerminalTabID) -> Void
  let closeOthers: (TerminalTabID) -> Void
  let closeToRight: (TerminalTabID) -> Void
  let closeAll: () -> Void
  let renameTab: (TerminalTabID, String) -> Void
  let hasNotification: (TerminalTabID) -> Bool
  let runningAgents: (TerminalTabID) -> [AgentPresenceManager.AgentInstance]

  @State private var draggingTabId: TerminalTabID?
  @State private var draggingStartLocation: CGFloat?
  @State private var openedTabs: [TerminalTabID] = []
  @State private var tabLocations: [TerminalTabID: CGRect] = [:]
  @State private var closeButtonGestureActive = false
  @State private var scrollOffset: CGFloat = 0
  @State private var contentWidth: CGFloat = 0
  @State private var containerWidth: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometryProxy in
      ScrollViewReader { scrollReader in
        ScrollView(.horizontal) {
          TerminalTabsRowView(
            manager: manager,
            openedTabs: $openedTabs,
            tabLocations: $tabLocations,
            draggingTabId: $draggingTabId,
            draggingStartLocation: $draggingStartLocation,
            closeButtonGestureActive: $closeButtonGestureActive,
            fixedTabWidth: effectiveTabWidth,
            closeTab: closeTab,
            closeOthers: closeOthers,
            closeToRight: closeToRight,
            closeAll: closeAll,
            renameTab: renameTab,
            hasNotification: hasNotification,
            runningAgents: runningAgents,
            scrollReader: scrollReader
          )
          .padding(.horizontal, TerminalTabBarMetrics.barPadding)
          .background(
            GeometryReader { contentGeo in
              Color.clear
                .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                  scrollOffset = -newFrame.minX
                  contentWidth = newFrame.width
                }
                .onAppear {
                  let frame = contentGeo.frame(in: .named("tabScroll"))
                  scrollOffset = -frame.minX
                  contentWidth = frame.width
                }
            }
          )
        }
        .scrollIndicators(.never)
        .coordinateSpace(name: "tabScroll")
        .onAppear {
          containerWidth = geometryProxy.size.width
          if let selectedId = manager.selectedTabId {
            scrollReader.scrollTo(selectedId, anchor: .center)
          }
        }
        .onChange(of: geometryProxy.size.width) { _, newWidth in
          containerWidth = newWidth
        }
        .onChange(of: manager.selectedTabId) { _, newTabId in
          if let tabId = newTabId {
            withAnimation(.easeInOut(duration: TerminalTabBarMetrics.selectionAnimationDuration)) {
              scrollReader.scrollTo(tabId, anchor: .center)
            }
          }
        }
      }
      .mask(
        HStack(spacing: 0) {
          // Edge regions fade the tabs into transparency when the strip can
          // scroll further in that direction; otherwise stay fully opaque so
          // the first/last tab isn't clipped.
          LinearGradient(
            colors: [canScrollLeft ? .clear : .white, .white],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: TerminalTabBarMetrics.overflowShadowWidth)
          Color.white.frame(maxWidth: .infinity)
          LinearGradient(
            colors: [.white, canScrollRight ? .clear : .white],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: TerminalTabBarMetrics.overflowShadowWidth)
        }
        .animation(
          reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration),
          value: canScrollLeft
        )
        .animation(
          reduceMotion ? nil : .easeInOut(duration: TerminalTabBarMetrics.fadeAnimationDuration),
          value: canScrollRight
        )
      )
    }
  }

  private var canScrollLeft: Bool {
    scrollOffset > 1
  }

  private var canScrollRight: Bool {
    contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
  }

  private var effectiveTabWidth: CGFloat? {
    let count = manager.tabs.count
    guard containerWidth > 0, count > 0 else { return nil }
    let perTab = containerWidth / CGFloat(count)
    return min(
      TerminalTabBarMetrics.tabMaxWidth,
      max(TerminalTabBarMetrics.tabMinWidth, perTab)
    )
  }
}
