#if os(macOS)
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class RemovalHelperStartTests: XCTestCase {
    func testASwitchedOffHelperIsOfferedBackWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .disabled, canInstall: true)),
        .switchedOff)
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .disabled, canInstall: false)), .scan)
    }

    func testACurrentHelperScansRightAway() {
      for canInstall in [true, false] {
        XCTAssertEqual(
          RemovalHelperStart(helper: HelperDisplay(status: .current, canInstall: canInstall)),
          .scan)
      }
    }

    func testAnOutdatedHelperIsReplacedFirstWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .outdated, canInstall: true)),
        .credentialsFirst)
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .outdated, canInstall: false)), .scan)
    }

    func testAMissingHelperAsksForTheAccountFirstWhenTheBuildCanInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .missing, canInstall: true)),
        .credentialsFirst)
    }

    func testAMissingHelperIsUnavailableWhenTheBuildCannotInstallIt() {
      XCTAssertEqual(
        RemovalHelperStart(helper: HelperDisplay(status: .missing, canInstall: false)),
        .unavailable)
    }

    func testEverySetupFailureSaysNothingChanged() {
      let errors: [any Error] = [
        EngineXPCSubmissionError.machineOwnerCredentialsRejected,
        InstallerHelperSetupError.cancelled,
        InstallerHelperSetupError.switchedOff,
        InstallerHelperSetupError.unavailable,
        InstallerHelperSetupError.failed("launchd"),
        CocoaError(.fileNoSuchFile),
      ]
      for error in errors {
        XCTAssertTrue(
          PlainLanguage.removalHelperSetupMessage(for: error).hasSuffix(
            "No disk changes were made."), "\(error)")
      }
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(
          for: EngineXPCSubmissionError.machineOwnerCredentialsRejected
        ).contains("not accepted"))
      XCTAssertTrue(
        PlainLanguage.removalHelperSetupMessage(for: InstallerHelperSetupError.switchedOff)
          .contains("Login Items"))
    }

    func testOnlyTheBuildThatCannotInstallTheHelperPointsAtThePackage() {
      XCTAssertTrue(PlainLanguage.removalServiceMissing.contains(PlainLanguage.installerPackage))
      XCTAssertFalse(
        PlainLanguage.removalServiceNotResponding.contains(PlainLanguage.installerPackage))
      XCTAssertFalse(PlainLanguage.removalCredentialsFirst.contains(PlainLanguage.installerPackage))
    }
  }
#endif
