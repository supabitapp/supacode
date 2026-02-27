import ComposableArchitecture
import Foundation

struct SSHKeyClient: Sendable {
  var generate: @Sendable (_ name: String) throws -> SSHKey
  var loadAll: @Sendable () -> [SSHKey]
  var delete: @Sendable (_ keyID: SSHKey.ID) throws -> Void
  var writeIdentityFile: @Sendable (_ keyID: SSHKey.ID) throws -> String
  var removeIdentityFile: @Sendable (_ keyID: SSHKey.ID) -> Void
  var publicKey: @Sendable (_ keyID: SSHKey.ID) -> String?
}

extension SSHKeyClient: DependencyKey {
  private static let indexKey = "supacode.mobile.sshkeys.index"

  static let liveValue: SSHKeyClient = {
    @Dependency(\.keychainClient) var keychainClient

    return SSHKeyClient(
      generate: { name in
        let generated = try SSHKeyGenerator.generate(name: name)
        let key = SSHKey(
          name: name,
          publicKey: generated.publicKey,
          fingerprint: generated.fingerprint,
        )
        try keychainClient.set(generated.privateKeyPEM, "sshkey.\(key.id.uuidString).pem")
        var keys = loadIndex()
        keys.append(key)
        saveIndex(keys)
        return key
      },
      loadAll: {
        loadIndex()
      },
      delete: { keyID in
        try? keychainClient.delete("sshkey.\(keyID.uuidString).pem")
        removeFile(for: keyID)
        var keys = loadIndex()
        keys.removeAll { $0.id == keyID }
        saveIndex(keys)
      },
      writeIdentityFile: { keyID in
        guard let pemData = try keychainClient.get("sshkey.\(keyID.uuidString).pem") else {
          throw SSHKeyClientError.keyNotFound
        }
        let dir = sshKeysDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent(keyID.uuidString)
        try pemData.write(to: filePath, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: filePath.path,
        )
        return filePath.path
      },
      removeIdentityFile: { keyID in
        removeFile(for: keyID)
      },
      publicKey: { keyID in
        loadIndex().first { $0.id == keyID }?.publicKey
      }
    )
  }()

  static let testValue = SSHKeyClient(
    generate: { _ in
      SSHKey(name: "test", publicKey: "ssh-ed25519 AAAA test", fingerprint: "SHA256:test")
    },
    loadAll: { [] },
    delete: { _ in },
    writeIdentityFile: { _ in "/tmp/test_key" },
    removeIdentityFile: { _ in },
    publicKey: { _ in nil }
  )

  private static func loadIndex() -> [SSHKey] {
    guard let data = UserDefaults.standard.data(forKey: indexKey),
      let keys = try? JSONDecoder().decode([SSHKey].self, from: data)
    else { return [] }
    return keys.sorted { $0.createdAt > $1.createdAt }
  }

  private static func saveIndex(_ keys: [SSHKey]) {
    guard let data = try? JSONEncoder().encode(keys) else { return }
    UserDefaults.standard.set(data, forKey: indexKey)
  }

  private static func sshKeysDirectory() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ssh_keys", isDirectory: true)
  }

  private static func removeFile(for keyID: SSHKey.ID) {
    let path = sshKeysDirectory().appendingPathComponent(keyID.uuidString)
    try? FileManager.default.removeItem(at: path)
  }
}

enum SSHKeyClientError: LocalizedError {
  case keyNotFound

  var errorDescription: String? {
    switch self {
    case .keyNotFound:
      "SSH key not found in keychain"
    }
  }
}

extension DependencyValues {
  var sshKeyClient: SSHKeyClient {
    get { self[SSHKeyClient.self] }
    set { self[SSHKeyClient.self] = newValue }
  }
}
