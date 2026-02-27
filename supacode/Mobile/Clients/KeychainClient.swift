import ComposableArchitecture
import Foundation
import Security

struct KeychainClient: Sendable {
  var set: @Sendable (Data, _ key: String) throws -> Void
  var get: @Sendable (_ key: String) throws -> Data?
  var delete: @Sendable (_ key: String) throws -> Void
  var setString: @Sendable (String, _ key: String) throws -> Void
  var getString: @Sendable (_ key: String) throws -> String?
}

enum KeychainError: LocalizedError, Equatable {
  case unhandled(OSStatus)
  case encodingFailed
  case decodingFailed

  var errorDescription: String? {
    switch self {
    case .unhandled(let status):
      "Keychain error: \(status)"
    case .encodingFailed:
      "Failed to encode data for keychain"
    case .decodingFailed:
      "Failed to decode data from keychain"
    }
  }
}

extension KeychainClient: DependencyKey {
  private static let service = "app.supabit.supacode.mobile"

  static let liveValue = KeychainClient(
    set: { data, key in
      let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
      SecItemDelete(deleteQuery as CFDictionary)

      let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      let status = SecItemAdd(addQuery as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw KeychainError.unhandled(status)
      }
    },
    get: { key in
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecReturnData as String: kCFBooleanTrue as Any,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      guard status != errSecItemNotFound else { return nil }
      guard status == errSecSuccess else {
        throw KeychainError.unhandled(status)
      }
      return item as? Data
    },
    delete: { key in
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.unhandled(status)
      }
    },
    setString: { value, key in
      guard let data = value.data(using: .utf8) else {
        throw KeychainError.encodingFailed
      }
      let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
      SecItemDelete(deleteQuery as CFDictionary)

      let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      let status = SecItemAdd(addQuery as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw KeychainError.unhandled(status)
      }
    },
    getString: { key in
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecReturnData as String: kCFBooleanTrue as Any,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      guard status != errSecItemNotFound else { return nil }
      guard status == errSecSuccess else {
        throw KeychainError.unhandled(status)
      }
      guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
        throw KeychainError.decodingFailed
      }
      return string
    }
  )

  static let testValue = KeychainClient(
    set: { _, _ in },
    get: { _ in nil },
    delete: { _ in },
    setString: { _, _ in },
    getString: { _ in nil }
  )
}

extension DependencyValues {
  var keychainClient: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}
