import ComposableArchitecture
import Sparkle

struct UpdaterClient {
  var configure: @MainActor @Sendable (_ checks: Bool, _ downloads: Bool, _ checkInBackground: Bool) -> Void
  var setUpdateChannel: @MainActor @Sendable (UpdateChannel) -> Void
  var checkForUpdates: @MainActor @Sendable () -> Void
}

@MainActor
class SparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
  var updateChannel: UpdateChannel = .stable

  nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    MainActor.assumeIsolated {
      switch updateChannel {
      case .stable:
        []
      case .tip:
        ["tip"]
      }
    }
  }
}

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = {
    let delegate = SparkleUpdateDelegate()
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: delegate,
      userDriverDelegate: nil
    )
    let updater = controller.updater
    return UpdaterClient(
      configure: { checks, downloads, checkInBackground in
        _ = controller
        updater.automaticallyChecksForUpdates = checks
        updater.automaticallyDownloadsUpdates = downloads
        if checkInBackground, checks {
          updater.checkForUpdatesInBackground()
        }
      },
      setUpdateChannel: { channel in
        _ = controller
        delegate.updateChannel = channel
        updater.updateCheckInterval = channel == .tip ? 900 : 3600
        if updater.automaticallyChecksForUpdates {
          updater.checkForUpdatesInBackground()
        }
      },
      checkForUpdates: {
        _ = controller
        updater.checkForUpdates()
      }
    )
  }()

  static let testValue = UpdaterClient(
    configure: { _, _, _ in },
    setUpdateChannel: { _ in },
    checkForUpdates: {}
  )
}

extension DependencyValues {
  var updaterClient: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
