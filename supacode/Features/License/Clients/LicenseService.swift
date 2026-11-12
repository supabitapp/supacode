import CryptoKit
import Foundation

nonisolated struct LicenseDevice: Sendable {
  let id: String
  let name: String
  let appVersion: String

  static func current() -> Self? {
    guard let hardwareID = HardwareInfo.uuid else { return nil }
    let digest = SHA256.hash(data: Data("app.supabit.supacode:device:v1:\(hardwareID)".utf8))
    return Self(
      id: digest.map { String(format: "%02x", $0) }.joined(),
      name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
    )
  }
}

nonisolated struct LicenseService: Sendable {
  var session: URLSession = .shared
  var baseURL = URL(string: "https://license.supacode.sh")!

  func request(_ operation: String, key: String, device: LicenseDevice) async throws -> String {
    struct Payload: Encodable {
      let licenseKey: String
      let deviceID: String
      let deviceName: String
      let appVersion: String
    }
    struct Success: Decodable { let token: String }
    var request = URLRequest(url: baseURL.appending(path: "v1/\(operation)"))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    request.httpBody = try encoder.encode(
      Payload(
        licenseKey: key, deviceID: device.id, deviceName: device.name, appVersion: device.appVersion
      )
    )
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw LicenseError.invalidEntitlement }
    guard http.statusCode == 200 else { throw Self.failure(from: data) }
    guard let success = try? JSONDecoder().decode(Success.self, from: data) else {
      throw LicenseError.invalidEntitlement
    }
    return success.token
  }

  static func failure(from data: Data) -> LicenseError {
    struct Failure: Decodable {
      struct Detail: Decodable { let message: String }
      let error: Detail
    }
    struct MacLimit: Decodable {
      struct Detail: Decodable {
        let deviceNames: [String]
        let portalRemoval: Bool?
      }
      let error: Detail
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let message = (try? decoder.decode(Failure.self, from: data))?.error.message else {
      return .service("The license service is unavailable. Try again.")
    }
    guard let limit = (try? decoder.decode(MacLimit.self, from: data))?.error,
      !limit.deviceNames.isEmpty
    else { return .service(message) }
    return .macLimitReached(
      message: message,
      LicenseMacLimit(macs: limit.deviceNames, canRemoveInPortal: limit.portalRemoval ?? false)
    )
  }
}
