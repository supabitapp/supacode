import AppKit
import SwiftUI

struct GhosttySurfaceSearchOverlay: View {
  let surfaceView: GhosttySurfaceView
  @Bindable var state: GhosttySurfaceState
  @Environment(GhosttyShortcutManager.self) private var ghosttyShortcuts

  @State private var searchText: String
  @State private var corner: GhosttySearchCorner = .topRight
  @State private var dragOffset: CGSize = .zero
  @State private var barSize: CGSize = .zero
  @State private var isSearchFieldFocused = false
  @State private var searchTask: Task<Void, Never>?

  private let overlayPadding: CGFloat = 8

  init(surfaceView: GhosttySurfaceView) {
    self.surfaceView = surfaceView
    self._state = Bindable(surfaceView.bridge.state)
    self._searchText = State(initialValue: surfaceView.bridge.state.searchNeedle ?? "")
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: corner.alignment) {
        HStack(spacing: 4) {
          GhosttySearchField(
            text: $searchText,
            isFocused: isSearchFieldFocused,
            onSubmit: { isShifted in
              navigateSearch(isShifted ? .previous : .next)
            },
            onEscape: {
              isSearchFieldFocused = false
              surfaceView.requestFocus()
            }
          )
          .frame(width: 180)
          .padding(.leading, 8)
          .padding(.trailing, 50)
          .padding(.vertical, 6)
          .background(Color.primary.opacity(0.1))
          .clipShape(.rect(cornerRadius: 6))
          .overlay(alignment: .trailing) {
            matchLabel
          }

          Button {
            navigateSearch(.next)
          } label: {
            SearchButtonLabel(
              title: "Next",
              shortcut: ghosttyShortcuts.display(for: "navigate_search:next"),
              systemImage: "chevron.up"
            )
          }
          .buttonStyle(GhosttySearchButtonStyle())

          Button {
            navigateSearch(.previous)
          } label: {
            SearchButtonLabel(
              title: "Previous",
              shortcut: ghosttyShortcuts.display(for: "navigate_search:previous"),
              systemImage: "chevron.down"
            )
          }
          .buttonStyle(GhosttySearchButtonStyle())

          Button {
            closeSearch()
          } label: {
            SearchButtonLabel(
              title: "Close",
              shortcut: ghosttyShortcuts.display(for: "end_search"),
              systemImage: "xmark"
            )
          }
          .buttonStyle(GhosttySearchButtonStyle())
        }
        .padding(8)
        .background(.background)
        .clipShape(GhosttySearchOverlayShape())
        .shadow(radius: 4)
        .background(
          GeometryReader { barGeo in
            Color.clear.onAppear {
              barSize = barGeo.size
            }
          }
        )
        .padding(overlayPadding)
        .offset(dragOffset)
        .contentShape(.rect)
        .gesture(
          DragGesture()
            .onChanged { value in
              dragOffset = value.translation
            }
            .onEnded { value in
              let centerPos = centerPosition(for: corner, in: geo.size, barSize: barSize)
              let newCenter = CGPoint(
                x: centerPos.x + value.translation.width,
                y: centerPos.y + value.translation.height
              )
              let newCorner = closestCorner(to: newCenter, in: geo.size)
              withAnimation(.easeOut(duration: 0.2)) {
                corner = newCorner
                dragOffset = .zero
              }
            }
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
      .onAppear {
        focusSearchField()
        scheduleSearch(searchText)
      }
      .onChange(of: searchText) { _, newValue in
        scheduleSearch(newValue)
      }
      .onChange(of: state.searchNeedle) { _, newValue in
        guard let newValue else { return }
        focusSearchField()
        if !newValue.isEmpty, newValue != searchText {
          searchText = newValue
        }
      }
      .onChange(of: state.searchFocusCount) { _, _ in
        focusSearchField()
      }
      .onDisappear {
        searchTask?.cancel()
        searchTask = nil
      }
    }
  }

  @ViewBuilder
  private var matchLabel: some View {
    if let selected = state.searchSelected {
      let totalLabel = state.searchTotal.map(String.init) ?? "?"
      Text("\(selected + 1)/\(totalLabel)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.trailing, 8)
    } else if let total = state.searchTotal {
      Text("-/\(total)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.trailing, 8)
    }
  }

  private func scheduleSearch(_ needle: String) {
    searchTask?.cancel()
    if needle.isEmpty || needle.count >= 3 {
      emitSearch(needle)
      return
    }

    let text = needle
    searchTask = Task { @MainActor in
      do {
        try await ContinuousClock().sleep(for: .milliseconds(300))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      emitSearch(text)
    }
  }

  private func emitSearch(_ needle: String) {
    surfaceView.performBindingAction("search:\(needle)")
  }

  private func navigateSearch(_ direction: GhosttySearchDirection) {
    flushPendingSearch()
    surfaceView.navigateSearch(direction)
  }

  private func closeSearch() {
    surfaceView.performBindingAction("end_search")
  }

  private func flushPendingSearch() {
    guard let searchTask else { return }
    searchTask.cancel()
    self.searchTask = nil
    emitSearch(searchText)
  }

  private func focusSearchField() {
    isSearchFieldFocused = false
    Task { @MainActor in
      await Task.yield()
      isSearchFieldFocused = true
    }
  }

  private func centerPosition(
    for corner: GhosttySearchCorner,
    in containerSize: CGSize,
    barSize: CGSize
  ) -> CGPoint {
    let halfWidth = barSize.width / 2 + overlayPadding
    let halfHeight = barSize.height / 2 + overlayPadding

    switch corner {
    case .topLeft:
      return CGPoint(x: halfWidth, y: halfHeight)
    case .topRight:
      return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
    case .bottomLeft:
      return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
    case .bottomRight:
      return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
    }
  }

  private func closestCorner(to point: CGPoint, in containerSize: CGSize) -> GhosttySearchCorner {
    let midX = containerSize.width / 2
    let midY = containerSize.height / 2

    if point.x < midX {
      return point.y < midY ? .topLeft : .bottomLeft
    }
    return point.y < midY ? .topRight : .bottomRight
  }
}

private enum GhosttySearchCorner {
  case topLeft
  case topRight
  case bottomLeft
  case bottomRight

  var alignment: Alignment {
    switch self {
    case .topLeft: return .topLeading
    case .topRight: return .topTrailing
    case .bottomLeft: return .bottomLeading
    case .bottomRight: return .bottomTrailing
    }
  }
}

private struct GhosttySearchOverlayShape: Shape {
  func path(in rect: CGRect) -> Path {
    if #available(macOS 26.0, *) {
      return ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true).path(in: rect)
    }
    return RoundedRectangle(cornerRadius: 8).path(in: rect)
  }
}

private struct SearchButtonLabel: View {
  let title: String
  let shortcut: String?
  let systemImage: String

  var body: some View {
    Label {
      if let shortcut {
        Text("\(title) \(Text("(\(shortcut))").foregroundColor(.secondary.opacity(0.7)))")
      } else {
        Text(title)
      }
    } icon: {
      Image(systemName: systemImage)
        .accessibilityHidden(true)
    }
  }
}

private struct GhosttySearchField: NSViewRepresentable {
  @Binding var text: String
  var isFocused: Bool
  var onSubmit: (Bool) -> Void
  var onEscape: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> SearchField {
    let field = SearchField()
    field.delegate = context.coordinator
    field.onSubmit = onSubmit
    field.onEscape = onEscape
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.placeholderString = "Search"
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return field
  }

  func updateNSView(_ nsView: SearchField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.onSubmit = onSubmit
    nsView.onEscape = onEscape

    if isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
      nsView.window?.makeFirstResponder(nsView)
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    @Binding var text: String

    init(text: Binding<String>) {
      _text = text
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      text = field.stringValue
    }
  }

  final class SearchField: NSTextField {
    var onSubmit: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
      onEscape?()
    }

    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 36, 76:
        onSubmit?(event.modifierFlags.contains(.shift))
      case 53:
        onEscape?()
      default:
        super.keyDown(with: event)
      }
    }
  }
}

private struct GhosttySearchButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
      .padding(.horizontal, 2)
      .frame(height: 26)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(backgroundColor(isPressed: configuration.isPressed))
      )
      .onHover { hovering in
        if hovering != isHovered {
          isHovered = hovering
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      }
      .onDisappear {
        if isHovered {
          isHovered = false
          NSCursor.pop()
        }
      }
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isPressed {
      return Color.primary.opacity(0.2)
    }
    if isHovered {
      return Color.primary.opacity(0.1)
    }
    return Color.clear
  }
}
