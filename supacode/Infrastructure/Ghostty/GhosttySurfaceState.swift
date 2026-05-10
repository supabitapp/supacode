import GhosttyKit
import Observation

@MainActor
@Observable
final class GhosttySurfaceState {
  var title: String?
  var pwd: String?
  var promptTitle: ghostty_action_prompt_title_e?
  var progressState: ghostty_action_progress_report_state_e?
  var progressValue: Int?
  var commandExitCode: Int?
  var commandDuration: UInt64?
  var childExitCode: UInt32?
  var childExitTimeMs: UInt64?
  var readOnly: ghostty_action_readonly_e?
  var mouseShape: ghostty_action_mouse_shape_e?
  var mouseVisibility: ghostty_action_mouse_visibility_e?
  var mouseOverLink: String?
  var rendererHealth: ghostty_action_renderer_health_e?
  var openUrl: String?
  var openUrlKind: ghostty_action_open_url_kind_e?
  var colorChangeKind: ghostty_action_color_kind_e?
  var colorChangeR: UInt8?
  var colorChangeG: UInt8?
  var colorChangeB: UInt8?
  var searchNeedle: String?
  var searchTotal: Int?
  var searchSelected: Int?
  var searchFocusCount = 0
  var sizeLimitMinWidth: UInt32?
  var sizeLimitMinHeight: UInt32?
  var sizeLimitMaxWidth: UInt32?
  var sizeLimitMaxHeight: UInt32?
  var initialSizeWidth: UInt32?
  var initialSizeHeight: UInt32?
  var keySequenceActive: Bool?
  var keySequenceTrigger: ghostty_input_trigger_s?
  var keyTableTag: ghostty_action_key_table_tag_e?
  var keyTableName: String?
  var keyTableDepth: Int = 0
  var secureInput: ghostty_action_secure_input_e?
  var floatWindow: ghostty_action_float_window_e?
  var reloadConfigSoft: Bool?
  var configChangeCount: Int = 0
  var bellCount: Int = 0
  var openConfigCount: Int = 0
  var presentTerminalCount: Int = 0
  var resetWindowSizeCount: Int = 0
  var quitTimer: ghostty_action_quit_timer_e?
}
