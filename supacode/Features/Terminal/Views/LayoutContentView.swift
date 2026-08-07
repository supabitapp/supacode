import AppKit
import ComposableArchitecture
import SwiftUI

/// Renders one worktree's pane tree: the split structure over panes, each pane
/// a tab strip above its selected content. Layout-agnostic; the parent sizes it.
struct LayoutContentView: View {
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  var dividerColor: Color = Color(nsColor: .separatorColor)

  var body: some View {
    if let node = store.layout.tree.visibleNode {
      PaneNodeView(node: node, store: store, runtime: runtime, dividerColor: dividerColor)
        .id(store.layout.tree.structuralIdentity)
    } else {
      EmptyLayoutView()
    }
  }
}

/// Shown when a layout has no panes: closing the final tab empties it until a
/// new tab is created.
private struct EmptyLayoutView: View {
  var body: some View {
    ContentUnavailableView("No Terminals", systemImage: "terminal")
  }
}

/// One node of the pane tree: a split renders its children with a draggable
/// divider, a leaf renders its pane.
private struct PaneNodeView: View {
  let node: SplitTree<PaneID>.Node
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color

  var body: some View {
    switch node {
    case .leaf(let paneID):
      PaneStripView(paneID: paneID, store: store, runtime: runtime)
    case .split(let split):
      PaneSplitView(node: node, split: split, store: store, runtime: runtime, dividerColor: dividerColor)
    }
  }
}

/// A split of two child nodes; the divider drag resizes and a double-click
/// equalizes, both through the reducer.
private struct PaneSplitView: View {
  let node: SplitTree<PaneID>.Node
  let split: SplitTree<PaneID>.Split
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime
  let dividerColor: Color

  var body: some View {
    SplitView(
      split.direction,
      ratio: split.ratio,
      dividerColor: dividerColor,
      left: {
        PaneNodeView(node: split.left, store: store, runtime: runtime, dividerColor: dividerColor)
      },
      right: {
        PaneNodeView(node: split.right, store: store, runtime: runtime, dividerColor: dividerColor)
      },
      onResize: { store.send(.resizePane(node: node, ratio: $0)) },
      onEqualize: { store.send(.equalizePanes) }
    )
  }
}

/// A pane: its tab strip and the selected tab's content. A single-tab pane
/// still shows its strip, matching the current chrome.
private struct PaneStripView: View {
  let paneID: PaneID
  let store: StoreOf<LayoutFeature>
  let runtime: ContentRuntime

  private var pane: Pane? { store.layout.panes[id: paneID] }
  private var isFocused: Bool { store.layout.focusedPaneID == paneID }

  var body: some View {
    if let pane {
      VStack(spacing: 0) {
        PaneTabStrip(pane: pane, isFocused: isFocused, store: store)
        Divider()
        if let contentID = pane.selectedTab?.content.id {
          ContentHostView(contentID: contentID, runtime: runtime)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Color.clear
        }
      }
      .contentShape(.rect)
      .onTapGesture { store.send(.focusPane(.pane(paneID))) }
      .accessibilityAddTraits(.isButton)
    }
  }
}

/// The horizontal strip of a pane's tabs, with the selected one highlighted.
private struct PaneTabStrip: View {
  let pane: Pane
  let isFocused: Bool
  let store: StoreOf<LayoutFeature>

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(pane.tabs) { tab in
          PaneTabButton(
            tab: tab,
            isSelected: pane.selectedTabID == tab.id,
            store: store
          )
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 3)
    }
    .background(isFocused ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
  }
}

/// A single tab in a pane strip; selects on click, closes on the accessory.
private struct PaneTabButton: View {
  let tab: TabItem
  let isSelected: Bool
  let store: StoreOf<LayoutFeature>

  var body: some View {
    HStack(spacing: 4) {
      Button {
        store.send(.selectTab(id: tab.id))
      } label: {
        Text(tab.customTitle ?? tab.title)
          .lineLimit(1)
          .font(.callout)
      }
      .buttonStyle(.plain)
      .help("Select this tab.")
      Button {
        store.send(.closeTab(id: tab.id))
      } label: {
        Image(systemName: "xmark")
          .imageScale(.small)
          .accessibilityLabel("Close tab")
      }
      .buttonStyle(.plain)
      .help("Close this tab.")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(isSelected ? Color(nsColor: .selectedControlColor) : .clear, in: .rect(cornerRadius: 6))
  }
}

/// Hosts a content's renderer view, resolved from the runtime and swapped when
/// the content hibernates or wakes.
private struct ContentHostView: NSViewRepresentable {
  let contentID: ContentID
  let runtime: ContentRuntime

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    mount(into: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    mount(into: container)
  }

  private func mount(into container: NSView) {
    let renderer = runtime.renderer(for: contentID)
    // Already showing the right renderer (or both nil): nothing to do.
    if container.subviews.first === renderer { return }
    container.subviews.forEach { $0.removeFromSuperview() }
    guard let renderer else { return }
    renderer.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(renderer)
    NSLayoutConstraint.activate([
      renderer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      renderer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      renderer.topAnchor.constraint(equalTo: container.topAnchor),
      renderer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
  }
}
