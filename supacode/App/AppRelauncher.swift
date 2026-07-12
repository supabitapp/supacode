import AppKit
import Foundation
import SupacodeSettingsShared

/// Relaunches the running app.
///
/// Spawns a detached shell that waits for this process to exit before reopening
/// the bundle — avoiding a second concurrent instance — then asks AppKit to
/// terminate so the normal `applicationWillTerminate` teardown (layout saves,
/// session persistence) runs first. Used to apply a language change, which only
/// takes effect on a fresh launch.
enum AppRelauncher {
  @MainActor static func relaunch() {
    let quotedBundlePath = "'" + Bundle.main.bundlePath.replacing("'", with: "'\\''") + "'"
    let pid = ProcessInfo.processInfo.processIdentifier
    let script =
      "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.1; done; /usr/bin/open \(quotedBundlePath)"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    do {
      try process.run()
    } catch {
      SupaLogger("Relaunch").error("Failed to spawn relaunch helper: \(error)")
      return
    }
    NSApp.terminate(nil)
  }
}
