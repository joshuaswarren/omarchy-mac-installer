#if os(macOS)
  import OmarchyAppleInstallerTrustCore
  import XCTest

  @testable import OmarchyInstallerUXCore

  final class RemovalHelperStartTests: XCTestCase {
    func testARegisteredHelperScansRightAway() {
      for status in [InstallerHelperStatus.current, .outdated, .disabled] {
        for canInstall in [true, false] {
          XCTAssertEqual(
            RemovalHelperStart(helper: HelperDisplay(status: status, canInstall: canInstall)),
            .scan, "\(status) canInstall=\(canInstall)")
        }
      }
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
