import AVFAudio
import AudioToolbox
import ComposableArchitecture
import Foundation

public enum CustomNotificationSoundImportError: Error, Equatable, LocalizedError, Sendable {
  case unsupportedFileType
  case unsupportedEncoding
  case unreadable
  case empty
  case tooLong

  public var errorDescription: String? {
    switch self {
    case .unsupportedFileType:
      "Choose an AIFF, WAV, or CAF audio file."
    case .unsupportedEncoding:
      "The sound must use Linear PCM, IMA4, µLaw, or aLaw encoding."
    case .unreadable:
      "Supacode could not read this audio file."
    case .empty:
      "The selected audio file is empty."
    case .tooLong:
      "Notification sounds must be shorter than 30 seconds."
    }
  }
}

nonisolated enum ManagedNotificationSoundStorage {
  static let fileNamePrefix = "supacode-custom-notification-"
  static let supportedExtensions: Set<String> = ["aif", "aiff", "caf", "wav"]
  static let supportedFormatIDs: Set<AudioFormatID> = [
    kAudioFormatLinearPCM,
    kAudioFormatAppleIMA4,
    kAudioFormatULaw,
    kAudioFormatALaw,
  ]

  static var defaultSoundsDirectory: URL {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appending(path: "Sounds", directoryHint: .isDirectory)
  }

  static func fileURL(
    for sound: CustomNotificationSound,
    soundsDirectory: URL = defaultSoundsDirectory
  ) -> URL? {
    guard sound.fileName.hasPrefix(fileNamePrefix),
      sound.fileName == URL(filePath: sound.fileName).lastPathComponent,
      supportedExtensions.contains(URL(filePath: sound.fileName).pathExtension.lowercased())
    else {
      return nil
    }
    return soundsDirectory.appending(path: sound.fileName, directoryHint: .notDirectory)
  }
}

public nonisolated struct CustomNotificationSoundClient: Sendable {
  public var importSound: @Sendable (_ sourceURL: URL) async throws -> CustomNotificationSound
  public var removeSound: @Sendable (_ sound: CustomNotificationSound) async throws -> Void

  public init(
    importSound:
      @escaping @Sendable (_ sourceURL: URL) async throws -> CustomNotificationSound,
    removeSound: @escaping @Sendable (_ sound: CustomNotificationSound) async throws -> Void
  ) {
    self.importSound = importSound
    self.removeSound = removeSound
  }

  static func fileSystem(
    soundsDirectory: URL,
    makeUUID: @escaping @Sendable () -> UUID = { UUID() },
    validate: @escaping @Sendable (URL) throws -> Void = { try Self.validate($0) },
    removeInvalidCopy: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.removeItem(at: $0)
    }
  ) -> Self {
    Self(
      importSound: { sourceURL in
        let fileManager = FileManager.default
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
          if accessed {
            sourceURL.stopAccessingSecurityScopedResource()
          }
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        guard ManagedNotificationSoundStorage.supportedExtensions.contains(fileExtension) else {
          throw CustomNotificationSoundImportError.unsupportedFileType
        }
        try validate(sourceURL)

        try fileManager.createDirectory(
          at: soundsDirectory,
          withIntermediateDirectories: true
        )
        let fileName =
          "\(ManagedNotificationSoundStorage.fileNamePrefix)\(makeUUID().uuidString.lowercased()).\(fileExtension)"
        let destinationURL = soundsDirectory.appending(path: fileName, directoryHint: .notDirectory)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        do {
          try validate(destinationURL)
        } catch {
          do {
            try removeInvalidCopy(destinationURL)
          } catch let cleanupError {
            SupaLogger("Notifications").warning(
              "Could not remove an invalid custom sound copy: \(cleanupError.localizedDescription)"
            )
          }
          throw error
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let displayName = baseName.isEmpty ? "Custom Sound" : baseName
        return CustomNotificationSound(displayName: displayName, fileName: fileName)
      },
      removeSound: { sound in
        let fileManager = FileManager.default
        guard
          let url = ManagedNotificationSoundStorage.fileURL(
            for: sound,
            soundsDirectory: soundsDirectory
          )
        else {
          throw CustomNotificationSoundImportError.unreadable
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
      }
    )
  }

  private static func validate(_ url: URL) throws {
    let readableFile: AVAudioFile
    do {
      readableFile = try AVAudioFile(forReading: url)
    } catch {
      throw CustomNotificationSoundImportError.unreadable
    }
    guard
      ManagedNotificationSoundStorage.supportedFormatIDs.contains(
        readableFile.fileFormat.streamDescription.pointee.mFormatID
      )
    else {
      throw CustomNotificationSoundImportError.unsupportedEncoding
    }
    guard readableFile.length > 0, readableFile.processingFormat.sampleRate > 0 else {
      throw CustomNotificationSoundImportError.empty
    }
    let duration = Double(readableFile.length) / readableFile.processingFormat.sampleRate
    guard duration < 30 else {
      throw CustomNotificationSoundImportError.tooLong
    }
  }

}

extension CustomNotificationSoundClient: DependencyKey {
  public static let liveValue = fileSystem(
    soundsDirectory: ManagedNotificationSoundStorage.defaultSoundsDirectory
  )

  public static let testValue = CustomNotificationSoundClient(
    importSound: { _ in
      throw CustomNotificationSoundImportError.unreadable
    },
    removeSound: { _ in }
  )
}

extension DependencyValues {
  public var customNotificationSoundClient: CustomNotificationSoundClient {
    get { self[CustomNotificationSoundClient.self] }
    set { self[CustomNotificationSoundClient.self] = newValue }
  }
}
