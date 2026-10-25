import SupacodeSettingsShared
import Testing

@testable import supacode

struct GhosttyConfigInputsTests {
  @Test func configInputsTrackResolvedTransparency() {
    var file = SettingsFile.default
    file.global.terminalBackgroundTransparencyEnabled = GlobalSettings.defaultTerminalBackgroundTransparency
    // Pinning the OS default changes nothing the config reads, so it must not reload.
    #expect(GhosttyConfigInputs(file) == GhosttyConfigInputs(.default))
    file.global.terminalBackgroundTransparencyEnabled = !GlobalSettings.defaultTerminalBackgroundTransparency
    #expect(GhosttyConfigInputs(file) != GhosttyConfigInputs(.default))
  }

  @Test func configInputsTrackThemeSyncAndUserConfigMode() {
    var file = SettingsFile.default
    file.global.terminalThemeSyncEnabled.toggle()
    #expect(GhosttyConfigInputs(file) != GhosttyConfigInputs(.default))
    file = .default
    file.global.ghosttyUserConfigMode = .exclusive
    #expect(GhosttyConfigInputs(file) != GhosttyConfigInputs(.default))
  }
}
