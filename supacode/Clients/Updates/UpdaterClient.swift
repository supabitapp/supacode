import ComposableArchitecture
import Sparkle
import SupacodeSettingsShared

nonisolated struct UpdaterClient: Sendable {
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

  nonisolated func updater(
    _ updater: SPUUpdater,
    shouldProceedWithUpdate item: SUAppcastItem,
    updateCheck: SPUUpdateCheck
  ) throws {
    guard LicenseBuild.isEnforced else { return }
    let record = try LicenseKeychain().load()
    guard let key = record.key, let credential = LicenseCredential(key),
      let token = record.token, let device = LicenseDevice.current()
    else { return }
    let codec = try LicenseEntitlementCodec(
      publicKeyRawRepresentation: Data(base64Encoded: LicenseBuild.publicKey)!
    )
    guard
      let entitlement = codec.decode(
        token: token, expectedDeviceID: device.id, expectedLicenseID: credential.licenseID
      )
    else { throw LicenseError.invalidEntitlement }
    guard entitlement.status == .active else { return }
    guard let published = item.date, let end = entitlement.updatesThrough,
      LicenseDay.today(at: published) <= end
    else {
      throw NSError(
        domain: "app.supabit.supacode.license", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "This update is outside your included updates.",
          NSLocalizedRecoverySuggestionErrorKey:
            "Renew updates in Supacode's License settings, or keep using your current release.",
        ]
      )
    }
  }
}

/// Sparkle's controller is main-actor only, so it starts on first use rather than on key resolution.
@MainActor
private enum SparkleUpdater {
  static let delegate = SparkleUpdateDelegate()
  static let controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: delegate,
    userDriverDelegate: nil
  )
}

nonisolated extension UpdaterClient: DependencyKey {
  static let liveValue = UpdaterClient(
    configure: { checks, downloads, checkInBackground in
      let updater = SparkleUpdater.controller.updater
      updater.automaticallyChecksForUpdates = checks
      updater.automaticallyDownloadsUpdates = downloads
      if checkInBackground, checks {
        updater.checkForUpdatesInBackground()
      }
    },
    setUpdateChannel: { channel in
      let updater = SparkleUpdater.controller.updater
      SparkleUpdater.delegate.updateChannel = channel
      updater.updateCheckInterval = channel == .tip ? 43200 : 259200
      if updater.automaticallyChecksForUpdates {
        updater.checkForUpdatesInBackground()
      }
    },
    checkForUpdates: {
      SparkleUpdater.controller.updater.checkForUpdates()
    }
  )

  static let testValue = UpdaterClient(
    configure: { _, _, _ in },
    setUpdateChannel: { _ in },
    checkForUpdates: {}
  )
}

nonisolated extension DependencyValues {
  var updaterClient: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
