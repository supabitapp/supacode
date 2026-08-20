import Foundation
import Testing

@testable import SupacodeSettingsShared

struct ForgeSettingsPersistenceTests {
  @Test func forgeEnabledByIDRoundTrips() throws {
    var settings = GlobalSettings.default
    settings.setForgeIntegrationEnabled(false, forID: "gitlab")

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

    #expect(decoded.forgeEnabledByID == ["gitlab": false])
    #expect(decoded.forgeIntegrationEnabled(forID: "gitlab") == false)
    #expect(decoded.forgeIntegrationEnabled(forID: "forgejo") == true)
  }

  @Test func githubEnablementStaysOnTheLegacyKey() throws {
    var settings = GlobalSettings.default
    settings.setForgeIntegrationEnabled(false, forID: "github")

    #expect(settings.githubIntegrationEnabled == false)
    #expect(settings.forgeEnabledByID["github"] == nil)
    #expect(settings.forgeIntegrationEnabled(forID: "github") == false)

    // Downgrade safety: the legacy key is always written.
    let data = try JSONEncoder().encode(settings)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["githubIntegrationEnabled"] as? Bool == false)
  }

  @Test func missingForgeKeysDecodeToDefaults() throws {
    // A pre-feature settings file is today's encoding minus the forge key.
    var settings = GlobalSettings.default
    settings.setForgeIntegrationEnabled(false, forID: "gitlab")
    let data = try JSONEncoder().encode(settings)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "forgeEnabledByID")
    let preFeatureData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: preFeatureData)
    #expect(decoded.forgeEnabledByID == [:])
    #expect(decoded.forgeIntegrationEnabled(forID: "gitlab") == true)
  }

  @Test func legacyIntegrationOptOutCarriesToNewForges() throws {
    // A pre-forge file with the legacy toggle off must not resurrect polling
    // through a newly introduced forge.
    var settings = GlobalSettings.default
    settings.githubIntegrationEnabled = false
    let data = try JSONEncoder().encode(settings)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "forgeEnabledByID")
    let preFeatureData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: preFeatureData)
    #expect(decoded.forgeIntegrationEnabled(forID: "github") == false)
    #expect(decoded.forgeIntegrationEnabled(forID: "gitlab") == false)
  }

  @Test func repositoryForgeIDRoundTripsAndInheritsWhenAbsent() throws {
    var settings = RepositorySettings.default
    settings.forgeID = "none"

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(decoded.forgeID == "none")

    // Inherit is an absent key, not null.
    var inherited = RepositorySettings.default
    inherited.forgeID = nil
    let inheritedData = try JSONEncoder().encode(inherited)
    let object = try JSONSerialization.jsonObject(with: inheritedData) as? [String: Any]
    #expect(object?.keys.contains("forgeID") == false)

    let decodedInherited = try JSONDecoder().decode(RepositorySettings.self, from: Data("{}".utf8))
    #expect(decodedInherited.forgeID == nil)
  }
}
