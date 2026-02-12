import Foundation
import Testing

@testable import supacode

@MainActor
struct AgentHookSignalMonitorTests {
  @Test func emitsWorkingAndIdleStatusFromSignalFiles() async throws {
    let fileManager = FileManager.default
    let signalsDirectory = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: signalsDirectory, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: signalsDirectory)
    }

    var events: [(UUID, Bool)] = []
    let monitor = AgentHookSignalMonitor(signalsDirectory: signalsDirectory, pollInterval: .milliseconds(20))
    monitor.onStatusChanged = { surfaceID, isWorking in
      events.append((surfaceID, isWorking))
    }

    monitor.startPolling()
    defer { monitor.stopPolling() }

    let surfaceID = UUID()
    let signalFileURL = signalsDirectory.appending(path: surfaceID.uuidString, directoryHint: .notDirectory)
    try Data("working\n".utf8).write(to: signalFileURL)

    let sawWorking = await waitUntil(timeout: .seconds(1)) {
      events.contains { $0.0 == surfaceID && $0.1 }
    }
    #expect(sawWorking)

    try fileManager.removeItem(at: signalFileURL)

    let sawIdle = await waitUntil(timeout: .seconds(1)) {
      events.contains { $0.0 == surfaceID && !$0.1 }
    }
    #expect(sawIdle)
  }

  @Test func startPollingClearsStaleSignalFiles() async throws {
    let fileManager = FileManager.default
    let signalsDirectory = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: signalsDirectory, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: signalsDirectory)
    }

    let staleSurfaceID = UUID()
    let staleFileURL = signalsDirectory.appending(path: staleSurfaceID.uuidString, directoryHint: .notDirectory)
    try Data("working\n".utf8).write(to: staleFileURL)

    var events: [(UUID, Bool)] = []
    let monitor = AgentHookSignalMonitor(signalsDirectory: signalsDirectory, pollInterval: .milliseconds(20))
    monitor.onStatusChanged = { surfaceID, isWorking in
      events.append((surfaceID, isWorking))
    }

    monitor.startPolling()
    defer { monitor.stopPolling() }

    let staleFileRemoved = await waitUntil(timeout: .seconds(1)) {
      !fileManager.fileExists(atPath: staleFileURL.path(percentEncoded: false))
    }

    #expect(staleFileRemoved)
    #expect(events.isEmpty)
  }

  @Test func stopPollingEmitsIdleForActiveSurface() async throws {
    let fileManager = FileManager.default
    let signalsDirectory = fileManager.temporaryDirectory.appending(
      path: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: signalsDirectory, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: signalsDirectory)
    }

    var events: [(UUID, Bool)] = []
    let monitor = AgentHookSignalMonitor(signalsDirectory: signalsDirectory, pollInterval: .milliseconds(20))
    monitor.onStatusChanged = { surfaceID, isWorking in
      events.append((surfaceID, isWorking))
    }

    monitor.startPolling()

    let surfaceID = UUID()
    let signalFileURL = signalsDirectory.appending(path: surfaceID.uuidString, directoryHint: .notDirectory)
    try Data("working\n".utf8).write(to: signalFileURL)

    let sawWorking = await waitUntil(timeout: .seconds(1)) {
      events.contains { $0.0 == surfaceID && $0.1 }
    }
    #expect(sawWorking)

    monitor.stopPolling()

    #expect(events.contains { $0.0 == surfaceID && !$0.1 })
  }

  private func waitUntil(timeout: Duration, condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
      if condition() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    return false
  }
}
