import Testing

@testable import supacode

struct AppLaunchModeTests {
  @Test func detectReturnsTestingWhenXCTestConfigurationExists() {
    let mode = AppLaunchMode.detect(
      environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
      processName: "supacode"
    )

    #expect(mode == .testing)
  }

  @Test func detectReturnsTestingWhenProcessNameContainsXCTest() {
    let mode = AppLaunchMode.detect(
      environment: [:],
      processName: "xctest"
    )

    #expect(mode == .testing)
  }

  @Test func detectReturnsNormalForRegularAppLaunch() {
    let mode = AppLaunchMode.detect(
      environment: [:],
      processName: "supacode"
    )

    #expect(mode == .normal)
  }
}
