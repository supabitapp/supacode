import Foundation
import Observation

@MainActor
@Observable
final class AgentHookSignalMonitor {
  var onStatusChanged: ((UUID, Bool) -> Void)?

  private let signalsDirectory: URL
  private let pollInterval: Duration
  private var pollingTask: Task<Void, Never>?
  private var workingSurfaceIDs: Set<UUID> = []

  init(
    signalsDirectory: URL = AgentHooksInstaller.signalsDirectory,
    pollInterval: Duration = .milliseconds(500)
  ) {
    self.signalsDirectory = signalsDirectory
    self.pollInterval = pollInterval
  }

  func startPolling() {
    stopPolling()
    clearSignalsDirectory()
    workingSurfaceIDs.removeAll()

    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        self.pollSignals()
        try? await Task.sleep(for: self.pollInterval)
      }
    }
  }

  func stopPolling() {
    pollingTask?.cancel()
    pollingTask = nil

    if !workingSurfaceIDs.isEmpty {
      for surfaceID in workingSurfaceIDs {
        onStatusChanged?(surfaceID, false)
      }
      workingSurfaceIDs.removeAll()
    }
  }

  private func pollSignals() {
    let currentSurfaceIDs = readSignalSurfaceIDs()
    let becameWorking = currentSurfaceIDs.subtracting(workingSurfaceIDs)
    let becameIdle = workingSurfaceIDs.subtracting(currentSurfaceIDs)

    if becameWorking.isEmpty && becameIdle.isEmpty {
      return
    }

    workingSurfaceIDs = currentSurfaceIDs

    for surfaceID in becameWorking {
      onStatusChanged?(surfaceID, true)
    }
    for surfaceID in becameIdle {
      onStatusChanged?(surfaceID, false)
    }
  }

  private func readSignalSurfaceIDs() -> Set<UUID> {
    ensureSignalsDirectoryExists()
    guard
      let fileURLs = try? FileManager.default.contentsOfDirectory(
        at: signalsDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var surfaceIDs: Set<UUID> = []
    for fileURL in fileURLs {
      if let surfaceID = UUID(uuidString: fileURL.lastPathComponent) {
        surfaceIDs.insert(surfaceID)
      }
    }
    return surfaceIDs
  }

  private func clearSignalsDirectory() {
    ensureSignalsDirectoryExists()
    guard
      let fileURLs = try? FileManager.default.contentsOfDirectory(
        at: signalsDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for fileURL in fileURLs {
      try? FileManager.default.removeItem(at: fileURL)
    }
  }

  private func ensureSignalsDirectoryExists() {
    try? FileManager.default.createDirectory(at: signalsDirectory, withIntermediateDirectories: true)
  }
}
