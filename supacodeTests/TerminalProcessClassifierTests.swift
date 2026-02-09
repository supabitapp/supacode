import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct TerminalProcessClassifierTests {
  @Test func categoryClassifiesKnownProcesses() {
    #expect(TerminalProcessClassifier.category(for: "zsh") == .shell)
    #expect(TerminalProcessClassifier.category(for: "vim") == .editor)
    #expect(TerminalProcessClassifier.category(for: "claude") == .aiTool)
    #expect(TerminalProcessClassifier.category(for: "less") == .pager)
    #expect(TerminalProcessClassifier.category(for: "ssh") == .ssh)
    #expect(TerminalProcessClassifier.category(for: "python") == .other)
  }

  @Test func shellStateUsesProgressReport() {
    #expect(TerminalProcessClassifier.shellState(from: nil) == .idle)
    #expect(TerminalProcessClassifier.shellState(from: GHOSTTY_PROGRESS_STATE_SET) == .running)
    #expect(
      TerminalProcessClassifier.shellState(from: GHOSTTY_PROGRESS_STATE_INDETERMINATE) == .running
    )
    #expect(TerminalProcessClassifier.shellState(from: GHOSTTY_PROGRESS_STATE_REMOVE) == .idle)
  }

  @Test func inferForegroundProcessFromTitle() {
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "vim - file.swift", pwd: nil) == "vim")
    #expect(
      TerminalForegroundProcessInference.infer(fromTitle: "claude | ~/Projects/app", pwd: nil) == "claude"
    )
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "  ", pwd: nil) == nil)
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "/Users/me", pwd: "/Users/me") == nil)
  }
}

