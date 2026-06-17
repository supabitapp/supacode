import Foundation
import Testing

@testable import supacode

struct ZedLaunchTests {
  private let appURL = URL(filePath: "/Applications/Zed.app")
  private let workingDirectory = URL(filePath: "/Users/me/code/worktree")

  @Test func cliURLPointsInsideAppBundle() {
    #expect(ZedLaunch.cliURL(appURL: appURL).path == "/Applications/Zed.app/Contents/MacOS/cli")
  }

  @Test func planUsesCLIWithWorktreePathWhenCLIExists() {
    let cliURL = ZedLaunch.cliURL(appURL: appURL)
    let plan = ZedLaunch.plan(cliURL: cliURL, cliExists: true, workingDirectory: workingDirectory)
    #expect(plan == .cli(executable: cliURL, arguments: ["/Users/me/code/worktree"]))
  }

  @Test func planFallsBackToWorkspaceOpenWhenCLIMissing() {
    let cliURL = ZedLaunch.cliURL(appURL: appURL)
    let plan = ZedLaunch.plan(cliURL: cliURL, cliExists: false, workingDirectory: workingDirectory)
    #expect(plan == .workspaceOpen(url: workingDirectory))
  }
}
