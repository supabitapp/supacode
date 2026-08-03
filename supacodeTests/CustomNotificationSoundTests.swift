import AVFAudio
import AppKit
import AudioToolbox
import Dependencies
import Foundation
import Testing

@testable import SupacodeSettingsShared

struct CustomNotificationSoundTests {
  @Test func importErrorsHaveActionableMessages() {
    #expect(
      CustomNotificationSoundImportError.unsupportedFileType.errorDescription
        == "Choose an AIFF, WAV, or CAF audio file."
    )
    #expect(
      CustomNotificationSoundImportError.unsupportedEncoding.errorDescription
        == "The sound must use Linear PCM, IMA4, µLaw, or aLaw encoding."
    )
    #expect(
      CustomNotificationSoundImportError.unreadable.errorDescription
        == "Supacode could not read this audio file."
    )
    #expect(
      CustomNotificationSoundImportError.empty.errorDescription
        == "The selected audio file is empty."
    )
    #expect(
      CustomNotificationSoundImportError.tooLong.errorDescription
        == "Notification sounds must be shorter than 30 seconds."
    )
  }

  @Test func importsValidLinearPCMSound() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "My Bell.wav")
    try SoundTestFixture.writeLinearPCM(to: source, duration: 1)
    let soundsDirectory = root.appending(path: "Library/Sounds", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)

    let client = CustomNotificationSoundClient.fileSystem(
      soundsDirectory: soundsDirectory,
      makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    )
    let imported = try await client.importSound(source)
    let importedURL = try #require(
      ManagedNotificationSoundStorage.fileURL(
        for: imported,
        soundsDirectory: soundsDirectory
      )
    )

    #expect(imported.displayName == "My Bell")
    #expect(
      imported.fileName == "supacode-custom-notification-00000000-0000-0000-0000-000000000001.wav")
    #expect(FileManager.default.fileExists(atPath: importedURL.path))
    #expect(try Data(contentsOf: importedURL) == Data(contentsOf: source))
    #expect(try AVAudioFile(forReading: importedURL).length > 0)

    let defaultUUIDClient = CustomNotificationSoundClient.fileSystem(
      soundsDirectory: root.appending(path: "Default UUID Sounds", directoryHint: .isDirectory)
    )
    let defaultUUIDImport = try await defaultUUIDClient.importSound(source)
    #expect(
      defaultUUIDImport.fileName.hasPrefix(ManagedNotificationSoundStorage.fileNamePrefix)
    )
  }

  @Test func rejectsUnsupportedFileExtension() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "sound.mp3")
    try Data("not audio".utf8).write(to: source)
    let client = CustomNotificationSoundClient.fileSystem(
      soundsDirectory: root.appending(path: "Sounds", directoryHint: .isDirectory)
    )

    await #expect(throws: CustomNotificationSoundImportError.unsupportedFileType) {
      try await client.importSound(source)
    }
  }

  @Test func rejectsUnreadableAndUnsupportedEncodedFiles() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "broken.wav")
    try Data("not audio".utf8).write(to: source)
    let client = CustomNotificationSoundClient.fileSystem(
      soundsDirectory: root.appending(path: "Sounds", directoryHint: .isDirectory)
    )

    await #expect(throws: CustomNotificationSoundImportError.unreadable) {
      try await client.importSound(source)
    }

    let unsupported = root.appending(path: "compressed.caf")
    try SoundTestFixture.writeAAC(to: unsupported, duration: 1)
    await #expect(throws: CustomNotificationSoundImportError.unsupportedEncoding) {
      try await client.importSound(unsupported)
    }
  }

  @Test func removesCopiedFileWhenPostCopyValidationFails() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "sound.wav")
    try SoundTestFixture.writeLinearPCM(to: source, duration: 1)
    let soundsDirectory = root.appending(path: "Sounds", directoryHint: .isDirectory)
    let validationCount = LockIsolated(0)
    let client = CustomNotificationSoundClient.fileSystem(
      soundsDirectory: soundsDirectory,
      validate: { _ in
        let count = validationCount.withValue {
          $0 += 1
          return $0
        }
        if count == 2 {
          throw CustomNotificationSoundImportError.unreadable
        }
      }
    )

    await #expect(throws: CustomNotificationSoundImportError.unreadable) {
      try await client.importSound(source)
    }
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: soundsDirectory.path)).isEmpty
    )
  }

  @Test func preservesValidationErrorWhenInvalidCopyCleanupFails() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "sound.wav")
    try SoundTestFixture.writeLinearPCM(to: source, duration: 1)
    let validationCount = LockIsolated(0)
    let client = CustomNotificationSoundClient.fileSystem(
      soundsDirectory: root.appending(path: "Sounds", directoryHint: .isDirectory),
      validate: { _ in
        if validationCount.withValue({ value in
          value += 1
          return value
        }) == 2 {
          throw CustomNotificationSoundImportError.unreadable
        }
      },
      removeInvalidCopy: { _ in
        throw CocoaError(.fileWriteNoPermission)
      }
    )

    await #expect(throws: CustomNotificationSoundImportError.unreadable) {
      try await client.importSound(source)
    }
  }

  @Test func rejectsEmptyAndThirtySecondSounds() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let soundsDirectory = root.appending(path: "Sounds", directoryHint: .isDirectory)
    let client = CustomNotificationSoundClient.fileSystem(soundsDirectory: soundsDirectory)

    let empty = root.appending(path: "empty.wav")
    try SoundTestFixture.writeLinearPCM(to: empty, duration: 0)
    await #expect(throws: CustomNotificationSoundImportError.empty) {
      try await client.importSound(empty)
    }

    let tooLong = root.appending(path: "long.wav")
    try SoundTestFixture.writeLinearPCM(to: tooLong, duration: 30)
    await #expect(throws: CustomNotificationSoundImportError.tooLong) {
      try await client.importSound(tooLong)
    }
  }

  @Test func removesManagedSoundAndIgnoresAlreadyMissingFile() async throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let soundsDirectory = root.appending(path: "Sounds", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
    let sound = CustomNotificationSound(
      displayName: "Bell",
      fileName: "supacode-custom-notification-bell.caf"
    )
    let soundURL = try #require(
      ManagedNotificationSoundStorage.fileURL(
        for: sound,
        soundsDirectory: soundsDirectory
      )
    )
    try Data("sound".utf8).write(to: soundURL)
    let client = CustomNotificationSoundClient.fileSystem(soundsDirectory: soundsDirectory)

    try await client.removeSound(sound)
    #expect(!FileManager.default.fileExists(atPath: soundURL.path))
    try await client.removeSound(sound)

    await #expect(throws: CustomNotificationSoundImportError.unreadable) {
      try await client.removeSound(
        CustomNotificationSound(displayName: "Unsafe", fileName: "../unsafe.wav")
      )
    }
  }

  @Test func systemNotificationSoundResolutionCoversEveryFallback() throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = CustomNotificationSound(
      displayName: "Bell",
      fileName: "supacode-custom-notification-bell.wav"
    )
    let customURL = try #require(
      ManagedNotificationSoundStorage.fileURL(for: custom, soundsDirectory: root)
    )
    try Data("sound".utf8).write(to: customURL)

    #expect(
      SystemNotificationSoundResolver.resolve(
        NotificationSoundConfiguration(sound: .custom, customSound: custom),
        soundsDirectory: root
      ) == .named(custom.fileName)
    )
    try FileManager.default.removeItem(at: customURL)
    #expect(
      SystemNotificationSoundResolver.resolve(
        NotificationSoundConfiguration(sound: .custom, customSound: custom),
        soundsDirectory: root
      ) == .default
    )
    #expect(
      SystemNotificationSoundResolver.resolve(
        NotificationSoundConfiguration(sound: .never, customSound: nil),
        soundsDirectory: root
      ) == .none
    )
    #expect(
      SystemNotificationSoundResolver.resolve(
        NotificationSoundConfiguration(sound: .supacodeClassic, customSound: nil),
        soundsDirectory: root
      ) == .named("notification.wav")
    )
    #expect(
      SystemNotificationSoundResolver.resolve(
        NotificationSoundConfiguration(sound: .hero, customSound: nil),
        soundsDirectory: root
      ) == .default
    )
  }

  @Test func inAppResolverLoadsManagedSoundAndRejectsMissingOrCorruptFiles() throws {
    let root = try SoundTestFixture.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = CustomNotificationSound(
      displayName: "Bell",
      fileName: "supacode-custom-notification-bell.wav"
    )
    let customURL = try #require(
      ManagedNotificationSoundStorage.fileURL(for: custom, soundsDirectory: root)
    )
    try SoundTestFixture.writeLinearPCM(to: customURL, duration: 1)
    let configuration = NotificationSoundConfiguration(sound: .custom, customSound: custom)

    let resolved = try #require(
      NotificationSoundResolver.make(configuration, soundsDirectory: root)
    )
    #expect(resolved.duration > 0)

    try Data("corrupt".utf8).write(to: customURL)
    #expect(NotificationSoundResolver.make(configuration, soundsDirectory: root) == nil)
    try FileManager.default.removeItem(at: customURL)
    #expect(NotificationSoundResolver.make(configuration, soundsDirectory: root) == nil)
  }

  @Test func rejectsUnsafeManagedFileNames() {
    let unsafe = CustomNotificationSound(
      displayName: "Unsafe",
      fileName: "../supacode-custom-notification-unsafe.wav"
    )
    #expect(ManagedNotificationSoundStorage.fileURL(for: unsafe) == nil)
    #expect(
      ManagedNotificationSoundStorage.fileURL(
        for: CustomNotificationSound(displayName: "Foreign", fileName: "foreign.wav")
      ) == nil
    )
    #expect(
      ManagedNotificationSoundStorage.fileURL(
        for: CustomNotificationSound(
          displayName: "MP3",
          fileName: "supacode-custom-notification-sound.mp3"
        )
      ) == nil
    )
    #expect(
      ManagedNotificationSoundStorage.defaultSoundsDirectory.lastPathComponent == "Sounds"
    )
  }

  @Test func dependencyTestValueFailsImportAndIgnoresRemoval() async throws {
    await #expect(throws: CustomNotificationSoundImportError.unreadable) {
      try await CustomNotificationSoundClient.testValue.importSound(
        URL(filePath: "/tmp/sound.wav")
      )
    }
    try await CustomNotificationSoundClient.testValue.removeSound(
      CustomNotificationSound(
        displayName: "Bell",
        fileName: "supacode-custom-notification-bell.wav"
      )
    )
  }
}

private enum SoundTestFixture {
  static func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "supacode-sound-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func writeLinearPCM(to url: URL, duration: TimeInterval) throws {
    let sampleRate = 8_000.0
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    guard frameCount > 0 else { return }
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCount
      )
    )
    buffer.frameLength = frameCount
    try file.write(from: buffer)
  }

  static func writeAAC(to url: URL, duration: TimeInterval) throws {
    let sampleRate = 44_100.0
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
      ]
    )
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let buffer = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCount
      )
    )
    buffer.frameLength = frameCount
    try file.write(from: buffer)
  }
}
