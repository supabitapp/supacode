import AppKit
import Foundation
import Testing

@testable import SupacodeSettingsShared

struct NotificationSoundTests {
  @MainActor
  @Test func cacheCoversBuiltInCustomAndFallbackPathsWithoutPlayingAudio() throws {
    NotificationSoundCache.sounds.removeAll()
    defer { NotificationSoundCache.sounds.removeAll() }
    let madeSound = try #require(NSSound(named: "Funk"))
    let builtIn = NotificationSoundConfiguration(sound: .funk, customSound: nil)
    var builtInMakeCount = 0

    #expect(
      NotificationSoundCache.resolve(builtIn) { _ in
        builtInMakeCount += 1
        return madeSound
      } === madeSound
    )
    #expect(
      NotificationSoundCache.resolve(builtIn) { _ in
        builtInMakeCount += 1
        return madeSound
      } === madeSound
    )
    #expect(builtInMakeCount == 1)

    let builtInWithCustomMetadata = NotificationSoundConfiguration(
      sound: .funk,
      customSound: CustomNotificationSound(
        displayName: "Unused",
        fileName: "supacode-custom-notification-unused.wav"
      )
    )
    #expect(
      NotificationSoundCache.resolve(builtInWithCustomMetadata) { _ in
        builtInMakeCount += 1
        return madeSound
      } === madeSound
    )
    #expect(builtInMakeCount == 1)

    let custom = NotificationSoundConfiguration(
      sound: .custom,
      customSound: CustomNotificationSound(
        displayName: "Bell",
        fileName: "supacode-custom-notification-bell.wav"
      )
    )
    var customMakeCount = 0
    #expect(
      NotificationSoundCache.resolve(custom) { _ in
        customMakeCount += 1
        return madeSound
      } === madeSound
    )
    #expect(
      NotificationSoundCache.resolve(custom) { _ in
        customMakeCount += 1
        return madeSound
      } === madeSound
    )
    #expect(customMakeCount == 2)

    var fallbackConfigurations: [NotificationSoundConfiguration] = []
    #expect(
      NotificationSoundCache.resolve(custom) { configuration in
        fallbackConfigurations.append(configuration)
        return configuration.sound == .hero ? madeSound : nil
      } === madeSound
    )
    #expect(
      fallbackConfigurations == [
        custom,
        NotificationSoundConfiguration(sound: .hero, customSound: nil),
      ]
    )

    NotificationSoundClient.live.play(
      NotificationSoundConfiguration(sound: .never, customSound: nil)
    )
    NotificationSoundClient.testValue.play(
      NotificationSoundConfiguration(sound: .never, customSound: nil)
    )
  }

  @Test func sourceMapsEachCaseToExactlyOneKind() {
    #expect(NotificationSound.never.source(customSound: nil) == nil)
    #expect(NotificationSound.funk.source(customSound: nil) == .system(name: "Funk"))
    #expect(NotificationSound.tink.source(customSound: nil) == .system(name: "Tink"))
    #expect(
      NotificationSound.supacodeClassic.source(customSound: nil)
        == .bundled(resource: "notification", withExtension: "wav")
    )
    let custom = CustomNotificationSound(
      displayName: "Bell", fileName: "supacode-custom-notification-id.wav")
    #expect(
      NotificationSound.custom.source(customSound: custom) == .custom(fileName: custom.fileName))
    #expect(NotificationSound.custom.source(customSound: nil) == nil)
  }

  @MainActor
  @Test func bundledSoundResolvesFromAppResources() {
    #expect(
      NotificationSoundResolver.make(
        NotificationSoundConfiguration(sound: .supacodeClassic, customSound: nil)
      ) != nil
    )
  }

  @MainActor
  @Test func bundledSoundResolutionHandlesMissingAndUnreadableResources() throws {
    let configuration = NotificationSoundConfiguration(
      sound: .supacodeClassic,
      customSound: nil
    )
    #expect(
      NotificationSoundResolver.make(
        configuration,
        bundledSoundURL: { _, _ in nil }
      ) == nil
    )

    let resourceURL = URL(filePath: "/tmp/unreadable-notification.wav")
    var requestedResource: (String, String)?
    var requestedSound: (URL, Bool)?
    #expect(
      NotificationSoundResolver.make(
        configuration,
        bundledSoundURL: { resource, fileExtension in
          requestedResource = (resource, fileExtension)
          return resourceURL
        },
        makeSound: { url, byReference in
          requestedSound = (url, byReference)
          return nil
        }
      ) == nil
    )
    #expect(requestedResource?.0 == "notification")
    #expect(requestedResource?.1 == "wav")
    #expect(requestedSound?.0 == resourceURL)
    #expect(requestedSound?.1 == true)
  }

  @Test func displayNamesAreUnambiguous() {
    #expect(NotificationSound.never.displayName == "Never")
    #expect(NotificationSound.supacodeClassic.displayName == "Supacode Classic")
    #expect(NotificationSound.custom.displayName == "Custom")
    #expect(NotificationSound.funk.displayName == "Funk")
  }

  @Test func pickerGroupsCoverEveryCaseWithoutOverlap() {
    let grouped =
      [NotificationSound.never] + NotificationSound.systemCases + [.supacodeClassic, .custom]
    #expect(Set(grouped) == Set(NotificationSound.allCases))
    #expect(grouped.count == NotificationSound.allCases.count)
  }

  @Test func systemNotificationDeliveryPolicyMatchesSupportedSounds() {
    #expect(NotificationSound.supacodeClassic.usesSelectedSoundForSystemNotifications)
    #expect(NotificationSound.custom.usesSelectedSoundForSystemNotifications)
    #expect(!NotificationSound.hero.usesSelectedSoundForSystemNotifications)
    #expect(!NotificationSound.never.usesSelectedSoundForSystemNotifications)
  }

  // The raw values are the persisted contract; a rename orphans saved
  // selections, so pin the literals here. Change them only as a deliberate edit.
  @Test func rawValueContractIsStable() throws {
    #expect(NotificationSound.never.rawValue == "never")
    #expect(NotificationSound.hero.rawValue == "hero")
    #expect(NotificationSound.supacodeClassic.rawValue == "supacodeClassic")
    #expect(NotificationSound.custom.rawValue == "custom")
    #expect(
      Set(NotificationSound.allCases.map(\.rawValue)) == [
        "never", "basso", "blow", "bottle", "frog", "funk", "glass", "hero",
        "morse", "ping", "pop", "purr", "sosumi", "submarine", "tink", "supacodeClassic",
        "custom",
      ]
    )
    // The persisted JSON string must still decode to the case.
    #expect(try JSONDecoder().decode(NotificationSound.self, from: Data("\"hero\"".utf8)) == .hero)
  }
}
