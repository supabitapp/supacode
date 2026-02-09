import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct TerminalProcessClassifierTests {
  @Test func displayNameMappings() {
    #expect(TerminalProcessClassifier.displayName(for: "claude") == "Claude Code")
    #expect(TerminalProcessClassifier.displayName(for: "CLAUDE") == "Claude Code")
    #expect(TerminalProcessClassifier.displayName(for: "ripgrep") == "ripgrep")
  }

  @Test func categoryClassifiesKnownProcesses() {
    #expect(TerminalProcessClassifier.category(for: "zsh") == .shell)
    #expect(TerminalProcessClassifier.category(for: "vim") == .editor)
    #expect(TerminalProcessClassifier.category(for: "claude") == .aiTool)
    #expect(TerminalProcessClassifier.category(for: "less") == .pager)
    #expect(TerminalProcessClassifier.category(for: "ssh") == .ssh)
    #expect(TerminalProcessClassifier.category(for: "python") == .other)
    #expect(TerminalProcessClassifier.category(for: "ZSH") == .shell)
  }

  @Test func shellStateUsesProgressReport() {
    #expect(
      TerminalProcessClassifier.shellState(progressState: nil, processCategory: .other) == .idle
    )
    #expect(
      TerminalProcessClassifier.shellState(progressState: nil, processCategory: .shell) == .waitingForInput
    )
    #expect(
      TerminalProcessClassifier.shellState(progressState: GHOSTTY_PROGRESS_STATE_SET, processCategory: .shell) == .running
    )
    #expect(
      TerminalProcessClassifier.shellState(
        progressState: GHOSTTY_PROGRESS_STATE_INDETERMINATE,
        processCategory: .shell
      ) == .running
    )
    #expect(
      TerminalProcessClassifier.shellState(progressState: GHOSTTY_PROGRESS_STATE_PAUSE, processCategory: .shell) == .running
    )
    #expect(
      TerminalProcessClassifier.shellState(progressState: GHOSTTY_PROGRESS_STATE_ERROR, processCategory: .shell) == .running
    )
  }

  @Test func inferForegroundProcessFromTitle() {
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "vim - file.swift", pwd: nil) == "vim")
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "Vimeo - Browse", pwd: nil) == nil)
    #expect(
      TerminalForegroundProcessInference.infer(fromTitle: "environment_vim_backup - foo", pwd: nil) == nil
    )
    #expect(
      TerminalForegroundProcessInference.infer(fromTitle: "claude | ~/Projects/app", pwd: nil) == "claude"
    )
    #expect(
      TerminalForegroundProcessInference.infer(fromTitle: "[git] claude | ~/Projects/app", pwd: nil) == "claude"
    )
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "claude: ~/Projects/app", pwd: nil) == "claude")
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "1234 - ~/Projects/app", pwd: nil) == nil)
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "/usr/bin/vim - foo", pwd: nil) == "vim")
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "  ", pwd: nil) == nil)
    #expect(TerminalForegroundProcessInference.infer(fromTitle: "/Users/me", pwd: "/Users/me") == nil)
  }
}
