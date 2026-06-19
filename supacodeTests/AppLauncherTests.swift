import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct AppLauncherTests {
  private let appURL = URL(filePath: "/Applications/Zed.app")
  private let workingDirectory = URL(filePath: "/Users/me/code/worktree")

  @Test func zedExposesBundledCLILauncher() {
    #expect(
      OpenWorktreeAction.zed.cliLauncher
        == .init(relativeExecutablePath: "Contents/MacOS/cli", openArguments: [])
    )
  }

  @Test func appsWithoutABundledCLIHaveNoLauncher() {
    #expect(OpenWorktreeAction.cursor.cliLauncher == nil)
    #expect(OpenWorktreeAction.finder.cliLauncher == nil)
  }

  @Test func planLaunchesCLIWithWorktreePathWhenAvailable() {
    let plan = AppLauncher.plan(
      launcher: OpenWorktreeAction.zed.cliLauncher,
      appURL: appURL,
      cliExists: true,
      workingDirectory: workingDirectory
    )
    #expect(
      plan == .cli(
        executable: appURL.appending(path: "Contents/MacOS/cli"),
        arguments: ["/Users/me/code/worktree"]
      )
    )
  }

  @Test func planFallsBackToWorkspaceOpenWhenCLIMissing() {
    let plan = AppLauncher.plan(
      launcher: OpenWorktreeAction.zed.cliLauncher,
      appURL: appURL,
      cliExists: false,
      workingDirectory: workingDirectory
    )
    #expect(plan == .workspaceOpen(url: workingDirectory))
  }

  @Test func planFallsBackToWorkspaceOpenWhenNoLauncher() {
    let plan = AppLauncher.plan(
      launcher: nil,
      appURL: appURL,
      cliExists: true,
      workingDirectory: workingDirectory
    )
    #expect(plan == .workspaceOpen(url: workingDirectory))
  }
}
