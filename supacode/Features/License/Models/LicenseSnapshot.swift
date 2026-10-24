import Foundation

nonisolated enum LicenseBuild {
  static var isEnforced: Bool {
    #if DEBUG
      false
    #else
      true
    #endif
  }

  static var releaseDay: LicenseDay? {
    (Bundle.main.object(forInfoDictionaryKey: "SupacodeReleaseDay") as? String)
      .flatMap(LicenseDay.init(rawValue:))
  }

  static let publicKey = "oce7dbnlB8EUn+WcH2gfkViQ+9KD6eblDuV9GjpRI8c="
}

nonisolated struct LicenseSnapshot: Equatable, Sendable {
  static let freeCreationLimit = 5
  var entitlement: LicenseEntitlement?
  var trialCreations = 0
  var isDevelopmentBuild = !LicenseBuild.isEnforced
  var releaseDay: LicenseDay? = LicenseBuild.releaseDay
  var updateSequence = 0

  var ownsCurrentRelease: Bool {
    guard let entitlement, entitlement.status == .active,
      let updatesThrough = entitlement.updatesThrough, let releaseDay
    else { return false }
    return releaseDay <= updatesThrough
  }

  var remainingCreations: Int {
    max(0, Self.freeCreationLimit - trialCreations)
  }

  var displayStatus: LicenseDisplayStatus {
    guard let entitlement else { return isDevelopmentBuild ? .developmentBuild : .notActivated }
    switch entitlement.status {
    case .active:
      // Mirrors trial charging: an active license that doesn't own this release still spends free creations.
      return ownsCurrentRelease || isDevelopmentBuild ? .active : .updatesExpired
    case .deactivated:
      return .deactivated
    case .revoked:
      return .revoked(reason: entitlement.revocationReason)
    case .transferred:
      return .transferred
    }
  }
}

nonisolated enum LicenseDisplayStatus: Equatable, Sendable {
  case developmentBuild
  case notActivated
  case active
  case updatesExpired
  case deactivated
  case revoked(reason: String?)
  case transferred
}

nonisolated struct LicenseCreationPermit: Equatable, Sendable {
  let id: UUID
}

nonisolated enum LicenseError: Error, Equatable, LocalizedError, Sendable {
  case licenseRequired
  case invalidKey
  case invalidEntitlement
  case missingDeviceIdentity
  case storageUnavailable
  case creationInProgress
  case trialCreationsPending
  case staleOperation
  case service(String)

  var errorDescription: String? {
    switch self {
    case .licenseRequired:
      "Your five free local worktree creations have been used. Activate a license to create more. SSH creation is free."
    case .invalidKey:
      "Enter a valid Supacode license key."
    case .invalidEntitlement:
      "The license server returned an invalid entitlement."
    case .missingDeviceIdentity:
      "Supacode could not identify this Mac. Try again after restarting the app."
    case .storageUnavailable:
      "Supacode could not read or save licensing data in Keychain. Unlock your login Keychain and try again."
    case .creationInProgress:
      "A worktree with this branch is already being created."
    case .trialCreationsPending:
      "Your remaining free local worktree creations are in progress. Wait for them to finish, then try again."
    case .staleOperation:
      "The license changed while this operation was running. Try again."
    case .service(let message):
      message
    }
  }
}
