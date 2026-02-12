import AppKit
import Foundation
import GhosttyKit

@MainActor
final class GhosttySurfaceBridge {
  let state = GhosttySurfaceState()
  var surface: ghostty_surface_t?
  weak var surfaceView: GhosttySurfaceView?
  var onTitleChange: ((String) -> Void)?
  var onSplitAction: ((GhosttySplitAction) -> Bool)?
  var onCloseRequest: ((Bool) -> Void)?
  var onNewTab: (() -> Bool)?
  var onCloseTab: ((ghostty_action_close_tab_mode_e) -> Bool)?
  var onGotoTab: ((ghostty_action_goto_tab_e) -> Bool)?
  var onMoveTab: ((ghostty_action_move_tab_s) -> Bool)?
  var onCommandPaletteToggle: (() -> Bool)?
  var onProgressReport: ((ghostty_action_progress_report_state_e) -> Void)?
  var onDesktopNotification: ((String, String) -> Void)?
  private var progressResetTask: Task<Void, Never>?

  deinit {
    progressResetTask?.cancel()
  }

  func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
    if let handled = handleAppAction(action) { return handled }
    if let handled = handleSplitAction(action) { return handled }
    if handleTitleAndPath(action) { return false }
    if handleCommandStatus(action) { return false }
    if handleMouseAndLink(action) { return false }
    if handleSearchAndScroll(action) { return false }
    if handleSizeAndKey(action) { return false }
    if handleConfigAndShell(action) { return false }
    return false
  }

  func sendText(_ text: String) {
    guard let surface else { return }
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(text.lengthOfBytes(using: .utf8)))
    }
  }

  func sendCommand(_ command: String) {
    let finalCommand = command.hasSuffix("\n") ? command : "\(command)\n"
    sendText(finalCommand)
  }

  func closeSurface(processAlive: Bool) {
    onCloseRequest?(processAlive)
  }

  private func handleAppAction(_ action: ghostty_action_s) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_NEW_TAB:
      return onNewTab?() ?? false
    case GHOSTTY_ACTION_CLOSE_TAB:
      return onCloseTab?(action.action.close_tab_mode) ?? false
    case GHOSTTY_ACTION_GOTO_TAB:
      return onGotoTab?(action.action.goto_tab) ?? false
    case GHOSTTY_ACTION_MOVE_TAB:
      return onMoveTab?(action.action.move_tab) ?? false
    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      return onCommandPaletteToggle?() ?? false
    case GHOSTTY_ACTION_GOTO_WINDOW,
      GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
      GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      return false
    case GHOSTTY_ACTION_UNDO:
      NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)
      return true
    case GHOSTTY_ACTION_REDO:
      NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil)
      return true
    default:
      return nil
    }
  }

  private func handleSplitAction(_ action: ghostty_action_s) -> Bool? {
    switch action.tag {
    case GHOSTTY_ACTION_NEW_SPLIT:
      let direction = splitDirection(from: action.action.new_split)
      guard let direction else { return false }
      return onSplitAction?(.newSplit(direction: direction)) ?? false

    case GHOSTTY_ACTION_GOTO_SPLIT:
      let direction = focusDirection(from: action.action.goto_split)
      guard let direction else { return false }
      return onSplitAction?(.gotoSplit(direction: direction)) ?? false

    case GHOSTTY_ACTION_RESIZE_SPLIT:
      let resize = action.action.resize_split
      let direction = resizeDirection(from: resize.direction)
      guard let direction else { return false }
      return onSplitAction?(.resizeSplit(direction: direction, amount: resize.amount)) ?? false

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      return onSplitAction?(.equalizeSplits) ?? false

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      return onSplitAction?(.toggleSplitZoom) ?? false

    default:
      return nil
    }
  }

  private func splitDirection(from value: ghostty_action_split_direction_e) -> GhosttySplitAction
    .NewDirection?
  {
    switch value {
    case GHOSTTY_SPLIT_DIRECTION_LEFT:
      return .left
    case GHOSTTY_SPLIT_DIRECTION_RIGHT:
      return .right
    case GHOSTTY_SPLIT_DIRECTION_UP:
      return .top
    case GHOSTTY_SPLIT_DIRECTION_DOWN:
      return .down
    default:
      return nil
    }
  }

  private func focusDirection(from value: ghostty_action_goto_split_e) -> GhosttySplitAction
    .FocusDirection?
  {
    switch value {
    case GHOSTTY_GOTO_SPLIT_PREVIOUS:
      return .previous
    case GHOSTTY_GOTO_SPLIT_NEXT:
      return .next
    case GHOSTTY_GOTO_SPLIT_LEFT:
      return .left
    case GHOSTTY_GOTO_SPLIT_RIGHT:
      return .right
    case GHOSTTY_GOTO_SPLIT_UP:
      return .top
    case GHOSTTY_GOTO_SPLIT_DOWN:
      return .down
    default:
      return nil
    }
  }

  private func resizeDirection(from value: ghostty_action_resize_split_direction_e)
    -> GhosttySplitAction.ResizeDirection?
  {
    switch value {
    case GHOSTTY_RESIZE_SPLIT_LEFT:
      return .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT:
      return .right
    case GHOSTTY_RESIZE_SPLIT_UP:
      return .top
    case GHOSTTY_RESIZE_SPLIT_DOWN:
      return .down
    default:
      return nil
    }
  }

  private func handleTitleAndPath(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
      if let title = string(from: action.action.set_title.title) {
        state.title = title
        onTitleChange?(title)
        if let surfaceView {
          NSAccessibility.post(element: surfaceView, notification: .titleChanged)
        }
      }
      return true

    case GHOSTTY_ACTION_PROMPT_TITLE:
      state.promptTitle = action.action.prompt_title
      return true

    case GHOSTTY_ACTION_PWD:
      state.pwd = string(from: action.action.pwd.pwd)
      if let surfaceView {
        NSAccessibility.post(element: surfaceView, notification: .valueChanged)
        // VoiceOver does not reliably re-read the label on `.valueChanged` alone.
        // If the surface view's label falls back to PWD, post `.titleChanged` to trigger re-announcement.
        let title = state.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
          NSAccessibility.post(element: surfaceView, notification: .titleChanged)
        }
      }
      return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      let note = action.action.desktop_notification
      let title = string(from: note.title) ?? ""
      let body = string(from: note.body) ?? ""
      guard !(title.isEmpty && body.isEmpty) else { return true }
      onDesktopNotification?(title, body)
      return true

    default:
      return false
    }
  }

  private func handleCommandStatus(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let report = action.action.progress_report
      progressResetTask?.cancel()
      state.progressValue = report.progress == -1 ? nil : Int(report.progress)
      if report.state == GHOSTTY_PROGRESS_STATE_REMOVE {
        state.progressState = nil
        state.progressValue = nil
        progressResetTask = nil
      } else {
        state.progressState = report.state
        progressResetTask = Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(15))
          guard let self, !Task.isCancelled else { return }
          self.state.progressState = nil
          self.state.progressValue = nil
          self.onProgressReport?(GHOSTTY_PROGRESS_STATE_REMOVE)
        }
      }
      onProgressReport?(report.state)
      return true

    case GHOSTTY_ACTION_COMMAND_FINISHED:
      let info = action.action.command_finished
      state.commandExitCode = info.exit_code == -1 ? nil : Int(info.exit_code)
      state.commandDuration = info.duration
      return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let info = action.action.child_exited
      state.childExitCode = info.exit_code
      state.childExitTimeMs = info.timetime_ms
      return true

    case GHOSTTY_ACTION_READONLY:
      state.readOnly = action.action.readonly
      return true

    case GHOSTTY_ACTION_RING_BELL:
      state.bellCount += 1
      return true

    default:
      return false
    }
  }

  private func handleMouseAndLink(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      state.mouseShape = action.action.mouse_shape
      surfaceView?.setMouseShape(action.action.mouse_shape)
      return true

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      state.mouseVisibility = action.action.mouse_visibility
      surfaceView?.setMouseVisibility(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
      return true

    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      state.mouseOverLink = string(from: link.url, length: link.len)
      return true

    case GHOSTTY_ACTION_RENDERER_HEALTH:
      state.rendererHealth = action.action.renderer_health
      return true

    case GHOSTTY_ACTION_OPEN_URL:
      let openUrl = action.action.open_url
      state.openUrlKind = openUrl.kind
      state.openUrl = string(from: openUrl.url, length: openUrl.len)
      return true

    case GHOSTTY_ACTION_COLOR_CHANGE:
      let change = action.action.color_change
      state.colorChangeKind = change.kind
      state.colorChangeR = change.r
      state.colorChangeG = change.g
      state.colorChangeB = change.b
      return true

    default:
      return false
    }
  }

  private func handleSearchAndScroll(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SCROLLBAR:
      let scroll = action.action.scrollbar
      surfaceView?.updateScrollbar(
        total: scroll.total,
        offset: scroll.offset,
        length: scroll.len
      )
      return true

    case GHOSTTY_ACTION_START_SEARCH:
      let needle = string(from: action.action.start_search.needle) ?? ""
      if !needle.isEmpty {
        state.searchNeedle = needle
      } else if state.searchNeedle == nil {
        state.searchNeedle = ""
      }
      state.searchTotal = nil
      state.searchSelected = nil
      state.searchFocusCount += 1
      return true

    case GHOSTTY_ACTION_END_SEARCH:
      state.searchNeedle = nil
      state.searchTotal = nil
      state.searchSelected = nil
      return true

    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = action.action.search_total.total
      state.searchTotal = total < 0 ? nil : Int(total)
      return true

    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = action.action.search_selected.selected
      state.searchSelected = selected < 0 ? nil : Int(selected)
      return true

    default:
      return false
    }
  }

  private func handleSizeAndKey(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SIZE_LIMIT:
      let sizeLimit = action.action.size_limit
      state.sizeLimitMinWidth = sizeLimit.min_width
      state.sizeLimitMinHeight = sizeLimit.min_height
      state.sizeLimitMaxWidth = sizeLimit.max_width
      state.sizeLimitMaxHeight = sizeLimit.max_height
      return true

    case GHOSTTY_ACTION_INITIAL_SIZE:
      let initial = action.action.initial_size
      state.initialSizeWidth = initial.width
      state.initialSizeHeight = initial.height
      return true

    case GHOSTTY_ACTION_CELL_SIZE:
      let cell = action.action.cell_size
      surfaceView?.updateCellSize(width: cell.width, height: cell.height)
      return true

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      state.resetWindowSizeCount += 1
      return true

    case GHOSTTY_ACTION_KEY_SEQUENCE:
      let seq = action.action.key_sequence
      state.keySequenceActive = seq.active
      state.keySequenceTrigger = seq.trigger
      return true

    case GHOSTTY_ACTION_KEY_TABLE:
      let table = action.action.key_table
      state.keyTableTag = table.tag
      switch table.tag {
      case GHOSTTY_KEY_TABLE_ACTIVATE:
        state.keyTableName = string(
          from: table.value.activate.name, length: table.value.activate.len)
        state.keyTableDepth += 1
      case GHOSTTY_KEY_TABLE_DEACTIVATE:
        state.keyTableName = nil
        if state.keyTableDepth > 0 {
          state.keyTableDepth -= 1
        }
      case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
        state.keyTableName = nil
        state.keyTableDepth = 0
      default:
        state.keyTableName = nil
      }
      return true

    default:
      return false
    }
  }

  private func handleConfigAndShell(_ action: ghostty_action_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SECURE_INPUT:
      state.secureInput = action.action.secure_input
      switch action.action.secure_input {
      case GHOSTTY_SECURE_INPUT_ON:
        surfaceView?.passwordInput = true
      case GHOSTTY_SECURE_INPUT_OFF:
        surfaceView?.passwordInput = false
      case GHOSTTY_SECURE_INPUT_TOGGLE:
        surfaceView?.passwordInput.toggle()
      default:
        break
      }
      return true

    case GHOSTTY_ACTION_FLOAT_WINDOW:
      state.floatWindow = action.action.float_window
      return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      state.reloadConfigSoft = action.action.reload_config.soft
      return true

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      state.configChangeCount += 1
      return true

    case GHOSTTY_ACTION_OPEN_CONFIG:
      state.openConfigCount += 1
      return true

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      state.presentTerminalCount += 1
      return true
    case GHOSTTY_ACTION_QUIT_TIMER:
      state.quitTimer = action.action.quit_timer
      return true

    default:
      return false
    }
  }

  private func string(from pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    return String(cString: pointer)
  }

  private func string(from pointer: UnsafePointer<CChar>?, length: Int) -> String? {
    guard let pointer, length > 0 else { return nil }
    let data = Data(bytes: pointer, count: length)
    return String(data: data, encoding: .utf8)
  }

  private func string(from pointer: UnsafePointer<CChar>?, length: UInt) -> String? {
    string(from: pointer, length: Int(length))
  }

  private func string(from pointer: UnsafePointer<CChar>?, length: UInt64) -> String? {
    string(from: pointer, length: Int(length))
  }
}
