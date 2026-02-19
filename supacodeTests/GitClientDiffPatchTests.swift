import Foundation
import Testing

@testable import supacode

actor DiffPatchShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientDiffPatchTests {
  @Test func diffPatchUsesPatchNoColorFlags() async throws {
    let store = DiffPatchShellCallStore()
    let patch = """
      diff --git a/file.txt b/file.txt
      index 0000000..1111111 100644
      --- a/file.txt
      +++ b/file.txt
      @@ -0,0 +1 @@
      +hello
      """
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: patch, stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    let result = try await client.diffPatch(at: URL(fileURLWithPath: "/tmp/repo"), baseRef: "HEAD")

    #expect(result == patch)
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.first == "git")
    #expect(args.contains("diff"))
    #expect(args.contains("HEAD"))
    #expect(args.contains("--patch"))
    #expect(args.contains("--no-color"))
  }

  @Test func diffPatchThrowsOnShellFailure() async {
    let shell = ShellClient(
      run: { _, _, _ in
        throw ShellClientError(command: "git diff", stdout: "", stderr: "bad", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell)

    await #expect(throws: GitClientError.self) {
      _ = try await client.diffPatch(at: URL(fileURLWithPath: "/tmp/repo"), baseRef: "HEAD")
    }
  }
}
