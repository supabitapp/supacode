import Foundation
import Testing

@testable import SupacodeSettingsShared

struct NotificationSoundTests {
  @Test func sourceMapsEachCaseToExactlyOneKind() {
    #expect(NotificationSound.never.source == nil)
    #expect(NotificationSound.funk.source == .system(name: "Funk"))
    #expect(NotificationSound.tink.source == .system(name: "Tink"))
    #expect(NotificationSound.supacodeClassic.source == .bundled(resource: "notification", withExtension: "wav"))
  }

  @Test func displayNamesAreUnambiguous() {
    #expect(NotificationSound.never.displayName == "Never")
    #expect(NotificationSound.supacodeClassic.displayName == "Supacode Classic")
    #expect(NotificationSound.funk.displayName == "Funk")
  }

  @Test func pickerGroupsCoverEveryCaseWithoutOverlap() {
    let grouped = [NotificationSound.never] + NotificationSound.systemCases + [.supacodeClassic]
    #expect(Set(grouped) == Set(NotificationSound.allCases))
    #expect(grouped.count == NotificationSound.allCases.count)
  }

  // The raw values are the persisted contract; a rename orphans saved
  // selections, so pin the literals here. Change them only as a deliberate edit.
  @Test func rawValueContractIsStable() throws {
    #expect(NotificationSound.never.rawValue == "never")
    #expect(NotificationSound.hero.rawValue == "hero")
    #expect(NotificationSound.supacodeClassic.rawValue == "supacodeClassic")
    #expect(
      Set(NotificationSound.allCases.map(\.rawValue)) == [
        "never", "basso", "blow", "bottle", "frog", "funk", "glass", "hero",
        "morse", "ping", "pop", "purr", "sosumi", "submarine", "tink", "supacodeClassic",
      ]
    )
    // The persisted JSON string must still decode to the case.
    #expect(try JSONDecoder().decode(NotificationSound.self, from: Data("\"hero\"".utf8)) == .hero)
  }
}
