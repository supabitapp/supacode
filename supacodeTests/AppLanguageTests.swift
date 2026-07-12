import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared

/// Shared helpers for the language tests.
private enum LanguageTestSupport {
  /// A fresh, isolated `UserDefaults` suite so tests never touch the real
  /// standard defaults or leak state between runs. Returns the suite name too,
  /// so tests can inspect the suite's *own* persistent domain — reads via the
  /// instance cascade into the global domain (where `AppleLanguages` lives),
  /// which would mask whether our override was actually removed.
  static func ephemeralSuite() -> (defaults: UserDefaults, name: String) {
    let name = "app-language-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (defaults, name)
  }

  static func ephemeralDefaults() -> UserDefaults {
    ephemeralSuite().defaults
  }

  /// The `AppleLanguages` override stored in the suite's own domain, ignoring
  /// the global-domain fallback.
  static func override(in defaults: UserDefaults, suiteName: String) -> [String]? {
    defaults.synchronize()
    return UserDefaults.standard.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String]
  }
}

struct AppLanguageTests {
  @Test func overrideMapping() {
    #expect(AppLanguage.system.appleLanguagesOverride == nil)
    #expect(AppLanguage.english.appleLanguagesOverride == ["en"])
    #expect(AppLanguage.simplifiedChinese.appleLanguagesOverride == ["zh-Hans"])
  }

  @Test func currentDefaultsToSystem() {
    #expect(AppLanguage.current(LanguageTestSupport.ephemeralDefaults()) == .system)
  }

  @Test func applyPersistsChoiceAndAppleLanguages() {
    let (defaults, name) = LanguageTestSupport.ephemeralSuite()
    AppLanguage.apply(.simplifiedChinese, to: defaults)
    #expect(AppLanguage.current(defaults) == .simplifiedChinese)
    #expect(LanguageTestSupport.override(in: defaults, suiteName: name) == ["zh-Hans"])
  }

  @Test func applySystemClearsAppleLanguagesOverride() {
    let (defaults, name) = LanguageTestSupport.ephemeralSuite()
    AppLanguage.apply(.english, to: defaults)
    #expect(LanguageTestSupport.override(in: defaults, suiteName: name) == ["en"])

    AppLanguage.apply(.system, to: defaults)
    #expect(AppLanguage.current(defaults) == .system)
    // The suite's own override is gone, so the app falls back to the system language.
    #expect(LanguageTestSupport.override(in: defaults, suiteName: name) == nil)
  }

  @Test func syncAtLaunchReappliesPersistedChoice() {
    let (defaults, name) = LanguageTestSupport.ephemeralSuite()
    defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.storageKey)
    // AppleLanguages override was cleared externally; sync should restore it.
    AppLanguage.syncAtLaunch(defaults)
    #expect(LanguageTestSupport.override(in: defaults, suiteName: name) == ["zh-Hans"])
  }
}

@MainActor
struct SettingsFeatureLanguageTests {
  @Test(.dependencies) func setPreferredLanguagePersistsAndFlagsRelaunch() async {
    let (appStorage, name) = LanguageTestSupport.ephemeralSuite()
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.defaultAppStorage = appStorage
    }

    await store.send(.setPreferredLanguage(.simplifiedChinese)) {
      $0.preferredLanguage = .simplifiedChinese
    }

    #expect(store.state.languageNeedsRelaunch)
    #expect(AppLanguage.current(appStorage) == .simplifiedChinese)
    #expect(LanguageTestSupport.override(in: appStorage, suiteName: name) == ["zh-Hans"])
  }

  @Test(.dependencies) func switchingBackToSystemClearsPendingRelaunch() async {
    let (appStorage, name) = LanguageTestSupport.ephemeralSuite()
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.defaultAppStorage = appStorage
    }

    await store.send(.setPreferredLanguage(.simplifiedChinese)) {
      $0.preferredLanguage = .simplifiedChinese
    }
    await store.send(.setPreferredLanguage(.system)) {
      $0.preferredLanguage = .system
    }

    // Back to the launch language, so no relaunch is needed and the override is cleared.
    #expect(!store.state.languageNeedsRelaunch)
    #expect(LanguageTestSupport.override(in: appStorage, suiteName: name) == nil)
  }

  @Test(.dependencies) func relaunchTapEmitsDelegate() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.defaultAppStorage = LanguageTestSupport.ephemeralDefaults()
    }

    await store.send(.relaunchForLanguageChangeTapped)
    await store.receive(\.delegate.relaunchRequested)
  }
}
