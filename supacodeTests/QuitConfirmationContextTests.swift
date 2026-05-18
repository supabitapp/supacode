import Testing

@testable import supacode

/// Direct unit tests for the 4-quadrant labels / message matrix. Cheaper to
/// drive than a full TestStore for each (terminateOnQuit, hasBlockingScripts)
/// combination, and surfaces a copy regression on its own line.
@MainActor
struct QuitConfirmationContextTests {
  // MARK: primaryLabel.

  @Test func primaryLabelDefaultCase() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: false, hasBlockingScripts: false)
    #expect(ctx.primaryLabel == "Quit")
  }

  @Test func primaryLabelWithBlockingScripts() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: false, hasBlockingScripts: true)
    #expect(ctx.primaryLabel == "Quit and Stop Scripts")
  }

  @Test func primaryLabelWithTerminateOnQuit() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: true, hasBlockingScripts: false)
    #expect(ctx.primaryLabel == "Quit and Terminate Sessions")
  }

  @Test func primaryLabelWithBothFlags() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: true, hasBlockingScripts: true)
    #expect(ctx.primaryLabel == "Quit and Stop Everything")
  }

  // MARK: destructiveLabel.

  @Test func destructiveLabelHiddenWhenTerminateOnQuit() {
    // The primary button already runs the destructive path; a duplicate would
    // be noise (and could read as a different action to the user).
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: true, hasBlockingScripts: false)
    #expect(ctx.destructiveLabel == nil)
  }

  @Test func destructiveLabelHiddenWhenTerminateAndBlockingScripts() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: true, hasBlockingScripts: true)
    #expect(ctx.destructiveLabel == nil)
  }

  @Test func destructiveLabelShownInDefaultMode() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: false, hasBlockingScripts: false)
    #expect(ctx.destructiveLabel == "Quit and Terminate Sessions")
  }

  @Test func destructiveLabelShownWithBlockingScripts() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: false, hasBlockingScripts: true)
    #expect(ctx.destructiveLabel == "Quit and Stop Everything")
  }

  // MARK: message.

  @Test func messageInDefaultCaseMentionsBackgroundSessions() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: false, hasBlockingScripts: false)
    #expect(ctx.message.contains("background"))
  }

  @Test func messageWithBlockingScriptsMentionsScriptLoss() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: false, hasBlockingScripts: true)
    #expect(ctx.message.contains("Running scripts will be stopped and lost"))
  }

  @Test func messageWithTerminateOnQuitMentionsTabsClosed() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: true, hasBlockingScripts: false)
    #expect(ctx.message.contains("All terminal tabs will be closed"))
  }

  @Test func messageWithBothFlagsMentionsBothLossAndTermination() {
    let ctx = AppFeature.QuitConfirmationContext(terminateOnQuit: true, hasBlockingScripts: true)
    #expect(ctx.message.contains("Running scripts will be stopped and lost"))
    #expect(ctx.message.contains("All terminal tabs will be closed"))
  }
}
