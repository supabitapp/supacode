import Testing
import UserNotifications

@testable import SupacodeSettingsShared

struct NotificationSoundTests {
  @Test func systemDefaultUsesDefaultBannerSound() {
    #expect(NotificationSound.systemDefault.unNotificationSound == .default)
  }

  @Test func chimeUsesNamedBundleSoundNotDefault() {
    // `.chime` resolves the bundled `notification.wav`, which is a distinct
    // `UNNotificationSound(named:)` instance — NOT the `.default` singleton.
    // `UNNotificationSound` is an `NSObject` subclass, so `==` compares via
    // `isEqual`; the named sound is not equal to the shared default.
    #expect(NotificationSound.chime.unNotificationSound != .default)
  }

  @Test func systemSoundsFallBackToDefaultOnBannerPath() {
    // Documented asymmetry: `/System/Library/Sounds` names don't resolve on the
    // UNUserNotificationCenter path, so they intentionally fall back to `.default`.
    #expect(NotificationSound.funk.unNotificationSound == .default)
    #expect(NotificationSound.tink.unNotificationSound == .default)
  }

  @Test func systemSoundNameMapsForSystemCasesOnly() {
    #expect(NotificationSound.funk.systemSoundName == "Funk")
    #expect(NotificationSound.tink.systemSoundName == "Tink")
    #expect(NotificationSound.chime.systemSoundName == nil)
    #expect(NotificationSound.systemDefault.systemSoundName == nil)
  }

  @Test func displayNamesAreUnambiguous() {
    #expect(NotificationSound.systemDefault.displayName == "System Default")
    #expect(NotificationSound.chime.displayName == "Supacode Chime")
    #expect(NotificationSound.funk.displayName == "Funk")
  }
}
