import Foundation

actor LicenseSession {
  private struct Reservation {
    let chargesTrial: Bool
    let resource: String?
    var localPath: String?
  }

  private let persistence: LicensePersistence
  private let device: LicenseDevice?
  private let codec: LicenseEntitlementCodec?
  private let releaseDay: LicenseDay?
  private let isEnforced: Bool
  private let request: @Sendable (String, String, LicenseDevice) async throws -> String
  private var record: LicenseRecord?
  private var reservations: [UUID: Reservation] = [:]
  private var generation = 0
  private var storageFailed = false
  private var updateSequence = 0

  init(
    persistence: LicensePersistence = .live,
    device: LicenseDevice? = .current(),
    publicKey: Data = Data(base64Encoded: LicenseBuild.publicKey)!,
    releaseDay: LicenseDay? = LicenseBuild.releaseDay,
    isEnforced: Bool = LicenseBuild.isEnforced,
    request: @escaping @Sendable (String, String, LicenseDevice) async throws -> String = {
      try await LicenseService().request($0, key: $1, device: $2)
    }
  ) {
    self.persistence = persistence
    self.device = device
    self.codec = try? LicenseEntitlementCodec(publicKeyRawRepresentation: publicKey)
    self.releaseDay = releaseDay
    self.isEnforced = isEnforced
    self.request = request
  }

  func load() throws -> LicenseSnapshot {
    if record == nil {
      var loaded = try persistence.load()
      if let pending = loaded.pendingWorktreePaths, !pending.isEmpty {
        let recovered = Set(pending.values).filter { path in
          FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: path).appending(path: ".git").path(percentEncoded: false))
        }.count
        loaded.trialCreations = min(
          LicenseSnapshot.freeCreationLimit, loaded.trialCreations + recovered)
        loaded.pendingWorktreePaths = nil
        try save(loaded)
      } else {
        record = loaded
      }
    }
    var snapshot = LicenseSnapshot()
    snapshot.trialCreations = record?.trialCreations ?? 0
    snapshot.releaseDay = releaseDay
    snapshot.isDevelopmentBuild = !isEnforced
    snapshot.updateSequence = updateSequence
    if let key = record?.key, let credential = LicenseCredential(key),
      let token = record?.token, let device
    {
      snapshot.entitlement = codec?.decode(
        token: token, expectedDeviceID: device.id, expectedLicenseID: credential.licenseID
      )
    }
    return snapshot
  }

  func authorizeCreation(resource: String?) throws -> LicenseCreationPermit {
    let snapshot = try load()
    if storageFailed, let record { try save(record) }
    if let resource, reservations.values.contains(where: { $0.resource == resource }) {
      throw LicenseError.creationInProgress
    }
    let chargesTrial = isEnforced && !snapshot.ownsCurrentRelease
    let pending = reservations.values.filter(\.chargesTrial).count
    if chargesTrial, snapshot.remainingCreations == 0 {
      throw LicenseError.licenseRequired(snapshot.displayStatus == .updatesExpired ? .renewal : .purchase)
    }
    if chargesTrial, snapshot.remainingCreations <= pending {
      throw LicenseError.trialCreationsPending
    }
    let permit = LicenseCreationPermit(id: UUID())
    reservations[permit.id] = Reservation(chargesTrial: chargesTrial, resource: resource)
    return permit
  }

  func completeCreation(_ permit: LicenseCreationPermit) throws -> LicenseSnapshot {
    guard let reservation = reservations.removeValue(forKey: permit.id) else { return try load() }
    if reservation.chargesTrial {
      var updated = record ?? LicenseRecord()
      updated.trialCreations += 1
      updated.pendingWorktreePaths?.removeValue(forKey: permit.id)
      try save(updated)
    }
    return try load()
  }

  func claimCreationResource(
    _ permit: LicenseCreationPermit, resource: String, localDirectory: URL? = nil
  ) throws {
    guard let reservation = reservations[permit.id] else { throw LicenseError.staleOperation }
    guard !reservations.contains(where: { $0.key != permit.id && $0.value.resource == resource })
    else {
      throw LicenseError.creationInProgress
    }
    let localPath = localDirectory?.standardizedFileURL.resolvingSymlinksInPath().path(
      percentEncoded: false)
    if reservation.chargesTrial, let path = localPath {
      guard !reservations.contains(where: { $0.key != permit.id && $0.value.localPath == path })
      else {
        throw LicenseError.creationInProgress
      }
      let gitPath = URL(fileURLWithPath: path).appending(path: ".git").path(percentEncoded: false)
      if !FileManager.default.fileExists(atPath: gitPath) {
        var updated = record ?? LicenseRecord()
        if updated.pendingWorktreePaths == nil { updated.pendingWorktreePaths = [:] }
        updated.pendingWorktreePaths?[permit.id] = path
        try save(updated)
      }
    }
    reservations[permit.id] = Reservation(
      chargesTrial: reservation.chargesTrial, resource: resource,
      localPath: localPath)
  }

  func cancelCreation(_ permit: LicenseCreationPermit) {
    reservations.removeValue(forKey: permit.id)
    if var updated = record, updated.pendingWorktreePaths?.removeValue(forKey: permit.id) != nil {
      try? save(updated)
    }
  }

  func activate(_ value: String) async throws -> LicenseSnapshot {
    let previous = try load()
    guard let credential = LicenseCredential(value) else { throw LicenseError.invalidKey }
    if previous.entitlement?.status == .active, let existing = record?.key,
      existing != credential.rawValue
    {
      throw LicenseError.service(
        "Deactivate your current license before activating a different license on this Mac.")
    }
    guard let device else { throw LicenseError.missingDeviceIdentity }
    generation += 1
    let operation = generation
    let token = try await request("activate", credential.rawValue, device)
    guard operation == generation else { throw LicenseError.staleOperation }
    let entitlement = try verified(token, credential: credential, device: device)
    guard entitlement.status == .active else {
      throw LicenseError.service(
        "This license is no longer active. Open the license portal for details.")
    }
    var updated = record ?? LicenseRecord()
    updated.key = credential.rawValue
    updated.token = token
    try save(updated)
    return try load()
  }

  func deactivate() async throws -> LicenseSnapshot {
    _ = try load()
    guard let key = record?.key, let credential = LicenseCredential(key) else { return try load() }
    guard let device else { throw LicenseError.missingDeviceIdentity }
    generation += 1
    let operation = generation
    let token = try await request("deactivate", key, device)
    guard operation == generation else { throw LicenseError.staleOperation }
    let entitlement = try verified(token, credential: credential, device: device)
    guard entitlement.status != .active else { throw LicenseError.invalidEntitlement }
    var updated = record ?? LicenseRecord()
    updated.key = nil
    updated.token = nil
    try save(updated)
    return try load()
  }

  func refresh() async throws -> LicenseSnapshot {
    let existing = try load()
    guard let key = record?.key, let credential = LicenseCredential(key), let device else {
      return existing
    }
    let operation = generation
    let token = try await request("refresh", key, device)
    guard operation == generation, record?.key == key else { return try load() }
    let entitlement = try verified(token, credential: credential, device: device)
    let current = try load()
    guard entitlement.revision >= (current.entitlement?.revision ?? 0) else { return current }
    var updated = record ?? LicenseRecord()
    updated.token = token
    try save(updated)
    return try load()
  }

  private func verified(
    _ token: String, credential: LicenseCredential, device: LicenseDevice
  ) throws -> LicenseEntitlement {
    guard
      let entitlement = codec?.decode(
        token: token, expectedDeviceID: device.id, expectedLicenseID: credential.licenseID
      )
    else { throw LicenseError.invalidEntitlement }
    return entitlement
  }

  private func save(_ updated: LicenseRecord) throws {
    record = updated
    updateSequence += 1
    do {
      try persistence.save(updated)
      storageFailed = false
    } catch {
      storageFailed = true
      throw LicenseError.storageUnavailable
    }
  }
}
