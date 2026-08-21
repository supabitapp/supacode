import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// A terminal's docked find bar, exposed to the layout as an opaque
/// `TabContentToolbar`. Reads the surface's own search state, so the bar shows
/// only while a search is active and stays scoped to that one surface.
@MainActor
@Observable
final class TerminalSearchToolbar: TabContentToolbar {
  let contentID: ContentID
  // Weak: `TerminalContent` is the sole owner of the surface. Set on session
  // start, cleared on hibernate/teardown so a dropped surface hides the bar.
  weak var surfaceView: GhosttySurfaceView?

  init(contentID: ContentID) {
    self.contentID = contentID
  }

  var view: AnyView? {
    guard let surfaceView else { return nil }
    // Pinned to the content id so a tab switch or wake rebuilds the slot's own
    // `@State` instead of leaking the previous surface's needle.
    return AnyView(TerminalFindBarSlot(surfaceView: surfaceView).id(contentID))
  }
}

/// A stable slot that observes the surface's search state and shows the bar only
/// while a search is active. Reading `searchNeedle` in a real view body (rather
/// than a computed property on the toolbar) keeps the appearance reactive: the
/// bar shows the instant the state changes, not only on the next remount.
private struct TerminalFindBarSlot: View {
  let surfaceView: GhosttySurfaceView
  @Bindable private var state: GhosttySurfaceState

  init(surfaceView: GhosttySurfaceView) {
    self.surfaceView = surfaceView
    self._state = Bindable(surfaceView.bridge.state)
  }

  var body: some View {
    if state.searchNeedle != nil {
      TerminalFindBar(surfaceView: surfaceView)
    }
  }
}

/// A native-styled find bar docked at the top of a terminal tab: a search
/// field with a match count and inline clear, previous/next navigation, and a
/// Done control. Drives Ghostty's custom search through binding actions.
struct TerminalFindBar: View {
  let surfaceView: GhosttySurfaceView
  @Bindable private var state: GhosttySurfaceState
  @Shared(.settingsFile) private var settingsFile

  @State private var searchText: String
  @State private var isSearchFieldFocused = false
  @State private var searchTask: Task<Void, Never>?

  init(surfaceView: GhosttySurfaceView) {
    self.surfaceView = surfaceView
    self._state = Bindable(surfaceView.bridge.state)
    self._searchText = State(initialValue: surfaceView.bridge.state.searchNeedle ?? "")
  }

  // One height for the field and the controls so nothing sits taller than a
  // small bordered button.
  private let controlHeight: CGFloat = 22

  var body: some View {
    HStack(spacing: 8) {
      FindSearchField(
        text: $searchText,
        isFocused: isSearchFieldFocused,
        matchText: Self.matchCountText(selected: state.searchSelected, total: state.searchTotal),
        height: controlHeight,
        onSubmit: { isShifted in navigateSearch(isShifted ? .previous : .next) },
        onEscape: { closeSearch() },
        onClear: { clearSearch() }
      )
      .frame(maxWidth: .infinity)

      ControlGroup {
        Button {
          navigateSearch(.previous)
        } label: {
          Label("Find Previous", systemImage: "chevron.left")
        }
        .help("Find Previous\(shortcutSuffix(for: AppShortcuts.findPrevious))")

        Button {
          navigateSearch(.next)
        } label: {
          Label("Find Next", systemImage: "chevron.right")
        }
        .help("Find Next\(shortcutSuffix(for: AppShortcuts.findNext))")
      }
      .controlGroupStyle(.navigation)
      .fixedSize()

      Button("Done") {
        closeSearch()
      }
      .buttonStyle(.bordered)
      .help("Hide the find bar (esc)")
    }
    .controlSize(.small)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .onAppear {
      focusSearchField()
      scheduleSearch(searchText)
    }
    .onChange(of: searchText) { _, newValue in
      scheduleSearch(newValue)
    }
    .onChange(of: state.searchNeedle) { _, newValue in
      guard let newValue, !newValue.isEmpty, newValue != searchText else { return }
      searchText = newValue
    }
    .onChange(of: state.searchFocusCount) { _, _ in
      focusSearchField()
    }
    .onDisappear {
      searchTask?.cancel()
      searchTask = nil
    }
  }

  /// The count shown inside the field: "selected/total" once a match is
  /// current, "-/total" while total is known but none is selected, else nil.
  static func matchCountText(selected: Int?, total: Int?) -> String? {
    if let selected, let total {
      return "\(selected + 1)/\(total)"
    }
    guard let total else { return nil }
    return "-/\(total)"
  }

  private func shortcutSuffix(for shortcut: AppShortcut) -> String {
    guard let effective = shortcut.effective(from: settingsFile.global.shortcutOverrides) else { return "" }
    return " (\(effective.display))"
  }

  private func scheduleSearch(_ needle: String) {
    searchTask?.cancel()
    // Short needles debounce; empty or 3+ characters emit at once.
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
    // Ghostty reports the needle only on start_search, not on these `search:`
    // edits, so keep the observable needle in step or a tab switch and remount
    // would restore a stale query and re-run it.
    state.searchNeedle = needle
    surfaceView.performBindingAction("search:\(needle)")
  }

  private func navigateSearch(_ direction: GhosttySearchDirection) {
    flushPendingSearch()
    surfaceView.navigateSearch(direction)
  }

  private func clearSearch() {
    searchText = ""
    focusSearchField()
  }

  private func closeSearch() {
    searchTask?.cancel()
    searchTask = nil
    surfaceView.performBindingAction("end_search")
    surfaceView.requestFocus()
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
}

/// The rounded search field: magnifier, editable needle, match count, and an
/// inline clear. A fixed height keeps it level with the bar's controls.
private struct FindSearchField: View {
  @Binding var text: String
  let isFocused: Bool
  let matchText: String?
  let height: CGFloat
  let onSubmit: (Bool) -> Void
  let onEscape: () -> Void
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      GhosttySearchField(
        text: $text,
        isFocused: isFocused,
        onSubmit: onSubmit,
        onEscape: onEscape
      )

      FindMatchLabel(text: matchText)

      Button {
        onClear()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Clear the search")
      .accessibilityLabel("Clear the search")
      .opacity(text.isEmpty ? 0 : 1)
      .disabled(text.isEmpty)
    }
    .padding(.horizontal, 6)
    .frame(height: height)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(nsColor: .textBackgroundColor))
    )
  }
}

/// The match count rendered inside the search field; a fixed monospaced slot so
/// the field does not jump as digits change.
private struct FindMatchLabel: View {
  let text: String?

  var body: some View {
    Text(text ?? "")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .accessibilityLabel(text.map { "\($0) matches" } ?? "")
  }
}

/// An `NSTextField` that reports edits, submits on Return (Shift-Return goes
/// backward), and closes on Escape, so the terminal's find bar behaves like a
/// native one.
private struct GhosttySearchField: NSViewRepresentable {
  @Binding var text: String
  var isFocused: Bool
  var onSubmit: (Bool) -> Void
  var onEscape: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onSubmit: onSubmit, onEscape: onEscape)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.delegate = context.coordinator
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.placeholderString = "Search"
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return field
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    context.coordinator.onSubmit = onSubmit
    context.coordinator.onEscape = onEscape
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    if isFocused, nsView.window?.firstResponder !== nsView.currentEditor() {
      nsView.window?.makeFirstResponder(nsView)
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    @Binding var text: String
    var onSubmit: (Bool) -> Void
    var onEscape: () -> Void

    init(text: Binding<String>, onSubmit: @escaping (Bool) -> Void, onEscape: @escaping () -> Void) {
      _text = text
      self.onSubmit = onSubmit
      self.onEscape = onEscape
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      text = field.stringValue
    }

    // The field editor consumes keyDown, so Return and Escape reach us as
    // editing commands instead. Shift is read from the live event so
    // Shift-Return searches backward.
    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
        onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        onEscape()
        return true
      default:
        return false
      }
    }
  }
}
