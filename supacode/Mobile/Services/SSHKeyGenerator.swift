import CryptoKit
import Foundation

struct GeneratedSSHKey: Sendable {
  let privateKeyPEM: Data
  let publicKey: String
  let fingerprint: String
}

enum SSHKeyGeneratorError: LocalizedError {
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .encodingFailed:
      "Failed to encode SSH key data"
    }
  }
}

enum SSHKeyGenerator {
  static func generate(name: String) throws -> GeneratedSSHKey {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey
    let comment = name.replacing(" ", with: "_")

    let privateKeyPEM = formatEd25519PrivateKey(privateKey, comment: comment)
    guard let pemData = privateKeyPEM.data(using: .utf8) else {
      throw SSHKeyGeneratorError.encodingFailed
    }

    let publicKeyString = formatEd25519PublicKey(publicKey, comment: comment)
    let fingerprint = calculateFingerprint(publicKeyData: publicKey.rawRepresentation)

    return GeneratedSSHKey(
      privateKeyPEM: pemData,
      publicKey: publicKeyString,
      fingerprint: fingerprint,
    )
  }

  // MARK: - Private Key Formatting

  private static func formatEd25519PrivateKey(
    _ key: Curve25519.Signing.PrivateKey,
    comment: String,
  ) -> String {
    let publicKeyBytes = key.publicKey.rawRepresentation
    let privateKeyBytes = key.rawRepresentation

    var publicBlob = Data()
    publicBlob.append(sshString("ssh-ed25519"))
    publicBlob.append(sshString(publicKeyBytes))

    let checkInt = UInt32.random(in: 0 ..< UInt32.max)
    var privateSection = Data()
    privateSection.append(uint32BE(checkInt))
    privateSection.append(uint32BE(checkInt))
    privateSection.append(sshString("ssh-ed25519"))
    privateSection.append(sshString(publicKeyBytes))
    var fullPrivateKey = Data(privateKeyBytes)
    fullPrivateKey.append(publicKeyBytes)
    privateSection.append(sshString(fullPrivateKey))
    privateSection.append(sshString(comment))

    let blockSize = 8
    let remainder = privateSection.count % blockSize
    if remainder != 0 {
      let needed = blockSize - remainder
      for i in 1 ... needed {
        privateSection.append(UInt8(i))
      }
    }

    var keyBlob = Data()
    keyBlob.append("openssh-key-v1".data(using: .utf8)!)
    keyBlob.append(0)
    keyBlob.append(sshString("none"))
    keyBlob.append(sshString("none"))
    keyBlob.append(sshString(Data()))
    keyBlob.append(uint32BE(1))
    keyBlob.append(sshString(publicBlob))
    keyBlob.append(sshString(privateSection))

    let base64 = keyBlob.base64EncodedString()
    let wrapped = wrapBase64(base64, lineLength: 70)
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)\n-----END OPENSSH PRIVATE KEY-----\n"
  }

  // MARK: - Public Key Formatting

  private static func formatEd25519PublicKey(
    _ key: Curve25519.Signing.PublicKey,
    comment: String,
  ) -> String {
    var blob = Data()
    blob.append(sshString("ssh-ed25519"))
    blob.append(sshString(key.rawRepresentation))

    let base64 = blob.base64EncodedString()
    return comment.isEmpty ? "ssh-ed25519 \(base64)" : "ssh-ed25519 \(base64) \(comment)"
  }

  // MARK: - Fingerprint

  private static func calculateFingerprint(publicKeyData: Data) -> String {
    var blob = Data()
    blob.append(sshString("ssh-ed25519"))
    blob.append(sshString(publicKeyData))

    let hash = SHA256.hash(data: blob)
    let base64 = Data(hash).base64EncodedString()
    return "SHA256:\(base64.replacing("=", with: ""))"
  }

  // MARK: - SSH Format Helpers

  private static func sshString(_ string: String) -> Data {
    sshString(string.data(using: .utf8)!)
  }

  private static func sshString(_ data: Data) -> Data {
    var result = Data()
    result.append(uint32BE(UInt32(data.count)))
    result.append(data)
    return result
  }

  private static func uint32BE(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: 4)
  }

  private static func wrapBase64(_ string: String, lineLength: Int) -> String {
    var result = ""
    var index = string.startIndex
    while index < string.endIndex {
      let endIndex = string.index(index, offsetBy: lineLength, limitedBy: string.endIndex) ?? string.endIndex
      if !result.isEmpty {
        result += "\n"
      }
      result += String(string[index ..< endIndex])
      index = endIndex
    }
    return result
  }
}
