import Clocks
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

// Serialized: the coalescing tests drive a TestClock with two concurrent
// sleepers (flush + stale watch); parallel execution can race `advance` before
// a task suspends and flake.
@MainActor
@Suite(.serialized)
struct GhosttySurfaceBridgeTests {
  @Test
  func openUrlRequestPreservesHTTPSURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "https://supacode.dev/changelog",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.kind == .unknown)
    #expect(request?.url.absoluteString == "https://supacode.dev/changelog")
    #expect(request?.url.isFileURL == false)
  }

  @Test
  func openUrlRequestTreatsTildePathAsFileURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "~/code/github.com/supabitapp/supacode",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
    #expect(
      request?.url.path
        == FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "code/github.com/supabitapp/supacode").path
    )
  }

  @Test
  func openUrlRequestExpandsNamedTildePathAsFileURL() {
    let username = NSUserName()
    let input = "~\(username)/code/github.com/supabitapp/supacode"
    let request = ghosttyOpenURLRequest(
      urlString: input,
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
    #expect(request?.url.path == NSString(string: input).expandingTildeInPath)
  }

  @Test
  func openUrlRequestTreatsPlainPathWithSpacesAsFileURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "/tmp/supa code/output.txt",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
    )

    #expect(request?.kind == .text)
    #expect(request?.url.isFileURL == true)
    #expect(request?.url.path == "/tmp/supa code/output.txt")
  }

  @Test
  func openUrlRequestTreatsUnknownStringAsFilePath() {
    let request = ghosttyOpenURLRequest(
      urlString: "relative/path",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
  }

  @Test
  func openUrlReturnsHandledResult() {
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    withOpenURLAction(url: "/tmp/test") { action in
      #expect(bridge.handleAction(target: target, action: action))
      #expect(bridge.state.openUrl == "/tmp/test")
      #expect(bridge.state.openUrlKind == action.action.open_url.kind)
    }
  }

  @Test func desktopNotificationEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: (title: String, body: String)?
    bridge.onDesktopNotification = { title, body in
      received = (title, body)
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    let target = ghostty_target_s()

    "Title".withCString { titlePtr in
      "Body".withCString { bodyPtr in
        action.action.desktop_notification = ghostty_action_desktop_notification_s(
          title: titlePtr,
          body: bodyPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(received?.title == "Title")
    #expect(received?.body == "Body")
  }

  @Test func contextSignalEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var receivedAction: UInt8?
    var receivedID: String?
    var receivedMetadata: String?
    bridge.onContextSignal = { action, id, metadata in
      receivedAction = action
      receivedID = id
      receivedMetadata = metadata
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONTEXT_SIGNAL
    let target = ghostty_target_s()

    "claude".withCString { idPtr in
      "event=busy".withCString { metaPtr in
        action.action.context_signal = ghostty_action_context_signal_s(
          action: 0,
          id: idPtr,
          metadata: metaPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(receivedAction == 0)
    #expect(receivedID == "claude")
    #expect(receivedMetadata == "event=busy")
  }

  @Test func contextSignalDropsNullIDOrMetadata() {
    let bridge = GhosttySurfaceBridge()
    var invoked = false
    bridge.onContextSignal = { _, _, _ in invoked = true }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONTEXT_SIGNAL
    let target = ghostty_target_s()

    // Null id with valid metadata.
    "event=busy".withCString { metaPtr in
      action.action.context_signal = ghostty_action_context_signal_s(
        action: 0,
        id: nil,
        metadata: metaPtr
      )
      _ = bridge.handleAction(target: target, action: action)
    }
    #expect(invoked == false)

    // Valid id with null metadata.
    "claude".withCString { idPtr in
      action.action.context_signal = ghostty_action_context_signal_s(
        action: 0,
        id: idPtr,
        metadata: nil
      )
      _ = bridge.handleAction(target: target, action: action)
    }
    #expect(invoked == false)
  }

  @Test func coalescesBurstOfProgressReports() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    // Leading edge applies the first report immediately; the rest coalesce.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 20)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    #expect(bridge.state.progressValue == 10)
    #expect(callbackCount == 1)

    // One throttle tick flushes only the latest coalesced value.
    await clock.advance(by: .milliseconds(50))
    #expect(bridge.state.progressValue == 50)
    #expect(callbackCount == 2)
  }

  @Test func staleProgressClearsAfterTimeout() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(200)
    )
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    // No further reports: the driver synthesizes a REMOVE once the window lapses.
    await clock.advance(by: .milliseconds(200))
    #expect(bridge.state.progressState == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  @Test func continuedReportsKeepProgressAlivePastStaleWindow() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(100)
    )
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // A long indeterminate run re-fires identical reports; the stale timer must
    // keep resetting even though the value never changes.
    for _ in 0..<6 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await clock.advance(by: .milliseconds(50))
    }
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func progressDriverRestartsAfterStaleRemoval() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .milliseconds(100)
    )
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // No further reports: the stale window synthesizes a REMOVE and tears down
    // the driver.
    await clock.advance(by: .milliseconds(100))
    #expect(bridge.state.progressState == nil)

    // A report after the stale REMOVE must re-arm the driver, not freeze.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    #expect(bridge.state.progressValue == 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 60)
    await clock.advance(by: .milliseconds(50))
    #expect(bridge.state.progressValue == 60)
  }

  @Test func determinateValuePaintsPromptlyAfterIdlePeriod() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    #expect(bridge.state.progressValue == 10)

    // Sit idle well past the throttle window, then a fresh value must paint on
    // its leading edge instead of waiting for a slow idle tick.
    await clock.advance(by: .seconds(1))
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    #expect(bridge.state.progressValue == 80)
  }

  @Test func identicalReportsNeverReapply() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(callbackCount == 1)

    // A flood of identical reports keeps the bar alive but never re-applies, so
    // the downstream callback fires exactly once across the whole stream.
    for _ in 0..<10 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await clock.advance(by: .milliseconds(50))
    }
    #expect(callbackCount == 1)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func removeWinsOverUnappliedTrailingValue() {
    let bridge = GhosttySurfaceBridge(
      clock: TestClock(),
      progressThrottleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var states: [ghostty_action_progress_report_state_e] = []
    bridge.onProgressReport = { states.append($0) }

    // First SET applies on the leading edge; the second sits un-applied in
    // pendingProgress because no throttle tick has fired yet.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 100)
    // REMOVE before the tick drops the trailing 100 and clears.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)

    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(states == [GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_REMOVE])
  }

  @Test func removeRacingRescheduleKeepsFlushHealthy() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(
      clock: clock,
      progressThrottleInterval: .milliseconds(50),
      progressIdleInterval: .milliseconds(50),
      progressStaleTimeout: .seconds(15)
    )
    var applied: [Int?] = []
    bridge.onProgressReport = { state in
      if state != GHOSTTY_PROGRESS_STATE_REMOVE { applied.append(bridge.state.progressValue) }
    }

    // REMOVE cancels the in-flight flush task while a new run starts at once.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 90)

    // The cancelled task resuming must not clobber the new run's flush handle:
    // each distinct value flushes exactly once (leading 50, leading 30 after
    // the REMOVE, trailing 90), with no redundant re-apply.
    await clock.advance(by: .milliseconds(50))
    #expect(bridge.state.progressValue == 90)
    #expect(applied == [50, 30, 90])
  }

  @Test func removeReportClearsImmediately() {
    let bridge = GhosttySurfaceBridge(clock: TestClock())
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 42)
    #expect(bridge.state.progressValue == 42)

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  // GhosttySurfaceBridge routes GHOSTTY_ACTION_COLOR_CHANGE by kind into three
  // independent state triples so OSC 10 / OSC 12 / palette traffic never disturbs
  // the background state that GhosttySurfaceView reads to paint the tint layer.

  private func colorChangeAction(
    kind: ghostty_action_color_kind_e,
    red: UInt8, green: UInt8, blue: UInt8
  ) -> ghostty_action_s {
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_COLOR_CHANGE
    action.action.color_change = ghostty_action_color_change_s(kind: kind, r: red, g: green, b: blue)
    return action
  }

  @Test func osc11PopulatesBackgroundTripleOnly() {
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: 26, green: 42, blue: 58)
    )

    #expect(bridge.state.backgroundColorR == 26)
    #expect(bridge.state.backgroundColorG == 42)
    #expect(bridge.state.backgroundColorB == 58)
    #expect(bridge.state.foregroundColorR == nil)
    #expect(bridge.state.foregroundColorG == nil)
    #expect(bridge.state.foregroundColorB == nil)
    #expect(bridge.state.cursorColorR == nil)
    #expect(bridge.state.cursorColorG == nil)
    #expect(bridge.state.cursorColorB == nil)
  }

  @Test func osc11ThenOsc10LeavesBackgroundUnchanged() {
    // OSC 10 (foreground color change) must not disturb the background triple
    // already set by OSC 11 — the tint layer must not disappear mid-session.
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: 10, green: 20, blue: 30)
    )
    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_FOREGROUND, red: 200, green: 200, blue: 200)
    )

    #expect(bridge.state.backgroundColorR == 10)
    #expect(bridge.state.backgroundColorG == 20)
    #expect(bridge.state.backgroundColorB == 30)
    #expect(bridge.state.foregroundColorR == 200)
    #expect(bridge.state.foregroundColorG == 200)
    #expect(bridge.state.foregroundColorB == 200)
  }

  @Test func osc11ThenOsc12LeavesBackgroundUnchanged() {
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: 10, green: 20, blue: 30)
    )
    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_CURSOR, red: 100, green: 100, blue: 100)
    )

    #expect(bridge.state.backgroundColorR == 10)
    #expect(bridge.state.backgroundColorG == 20)
    #expect(bridge.state.backgroundColorB == 30)
    #expect(bridge.state.cursorColorR == 100)
    #expect(bridge.state.cursorColorG == 100)
    #expect(bridge.state.cursorColorB == 100)
  }

  @Test func osc11ThenPaletteKindLeavesBackgroundUnchanged() {
    // Positive kind values are OSC 4 palette-index changes. They must not touch
    // any of the three named triples.
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: 10, green: 20, blue: 30)
    )
    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: ghostty_action_color_kind_e(rawValue: 0), red: 255, green: 0, blue: 0)
    )

    #expect(bridge.state.backgroundColorR == 10)
    #expect(bridge.state.backgroundColorG == 20)
    #expect(bridge.state.backgroundColorB == 30)
    #expect(bridge.state.foregroundColorR == nil)
    #expect(bridge.state.cursorColorR == nil)
  }

  @Test func osc10WithNoPriorOsc11LeavesBackgroundNil() {
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    _ = bridge.handleAction(
      target: target,
      action: colorChangeAction(kind: GHOSTTY_ACTION_COLOR_KIND_FOREGROUND, red: 255, green: 255, blue: 255)
    )

    #expect(bridge.state.backgroundColorR == nil)
    #expect(bridge.state.backgroundColorG == nil)
    #expect(bridge.state.backgroundColorB == nil)
  }

  private func withOpenURLAction<T>(
    url: String,
    kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
    _ body: (ghostty_action_s) -> T
  ) -> T {
    var action = ghostty_action_s(tag: GHOSTTY_ACTION_OPEN_URL, action: .init())
    action.action.open_url.kind = kind
    guard let pointer = strdup(url) else {
      Issue.record("strdup failed")
      return body(action)
    }
    defer {
      free(pointer)
    }
    action.action.open_url.url = UnsafePointer(pointer)
    action.action.open_url.len = UInt(strlen(pointer))
    return body(action)
  }
}
