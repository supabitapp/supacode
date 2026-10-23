import ComposableArchitecture
import Foundation

nonisolated struct LicensePersistence: Sendable {
  var load: @Sendable () throws -> LicenseRecord
  var save: @Sendable (LicenseRecord) throws -> Void

  static var live: Self {
    let keychain = LicenseKeychain()
    return Self(load: keychain.load, save: keychain.save)
  }
}

nonisolated struct LicenseClient: Sendable {
  var isEnforced: Bool
  var load: @Sendable () async throws -> LicenseSnapshot
  var activate: @Sendable (String) async throws -> LicenseSnapshot
  var deactivate: @Sendable () async throws -> LicenseSnapshot
  var refresh: @Sendable () async throws -> LicenseSnapshot
  var authorizeCreation: @Sendable (String?) async throws -> LicenseCreationPermit
  var claimCreationResource: @Sendable (LicenseCreationPermit, String, URL?) async throws -> Void
  var completeCreation: @Sendable (LicenseCreationPermit) async throws -> LicenseSnapshot
  var cancelCreation: @Sendable (LicenseCreationPermit) async -> Void
}

nonisolated extension LicenseClient: DependencyKey {
  static let liveValue: Self = {
    let session = LicenseSession()
    return Self(
      isEnforced: LicenseBuild.isEnforced,
      load: { try await session.load() },
      activate: { try await session.activate($0) },
      deactivate: { try await session.deactivate() },
      refresh: { try await session.refresh() },
      authorizeCreation: { try await session.authorizeCreation(resource: $0) },
      claimCreationResource: {
        try await session.claimCreationResource($0, resource: $1, localDirectory: $2)
      },
      completeCreation: { try await session.completeCreation($0) },
      cancelCreation: { await session.cancelCreation($0) }
    )
  }()

  static let testValue = Self(
    isEnforced: false,
    load: { LicenseSnapshot() },
    activate: { _ in throw LicenseError.invalidKey },
    deactivate: { LicenseSnapshot() },
    refresh: { LicenseSnapshot() },
    authorizeCreation: { _ in LicenseCreationPermit(id: UUID()) },
    claimCreationResource: { _, _, _ in },
    completeCreation: { _ in LicenseSnapshot() },
    cancelCreation: { _ in }
  )
}
