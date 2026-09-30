#if os(macOS)
  import Darwin
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class PackageInstalledAppRetirementTests: XCTestCase {
    private var applications: URL!

    override func setUpWithError() throws {
      applications = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
      try? FileManager.default.removeItem(at: applications)
    }

    func testRemovesIdlePackageInstalledCopiesUnderEitherName() throws {
      try makeBundle("Current")
      try makeBundle("Legacy")

      let results = retirement().run()

      XCTAssertEqual(results, ["Current.app": .removed, "Legacy.app": .removed])
      XCTAssertFalse(exists("Current.app"))
      XCTAssertFalse(exists("Legacy.app"))
    }

    func testReportsAbsentBundles() {
      XCTAssertEqual(retirement().run(), ["Current.app": .absent, "Legacy.app": .absent])
    }

    func testKeepsALink() throws {
      try makeBundle("Elsewhere")
      try FileManager.default.createSymbolicLink(
        at: applications.appendingPathComponent("Current.app"),
        withDestinationURL: applications.appendingPathComponent("Elsewhere.app"))

      XCTAssertEqual(retirement().run()["Current.app"], .keptLink)
      XCTAssertTrue(exists("Elsewhere.app"))
    }

    func testKeepsABundleWithAnotherIdentifier() throws {
      try makeBundle("Current", identifier: "someone.else")

      XCTAssertEqual(retirement().run()["Current.app"], .keptForeignIdentifier("someone.else"))
      XCTAssertTrue(exists("Current.app"))
    }

    func testKeepsACopyThePersonPutThere() throws {
      try makeBundle("Current")
      // The package installs as root; this copy belongs to the test user.
      let results = retirement(packageOwner: getuid() == 0 ? 501 : 0).run()

      XCTAssertEqual(results["Current.app"], .keptNotInstalledByPackage)
      XCTAssertTrue(exists("Current.app"))
    }

    func testKeepsARunningCopy() throws {
      try makeBundle("Current")
      let running = applications.appendingPathComponent("Current.app/Contents/MacOS/app").path

      XCTAssertEqual(retirement(running: [running]).run()["Current.app"], .keptRunning)
      XCTAssertTrue(exists("Current.app"))
    }

    func testAProcessBesideTheBundleDoesNotCountAsRunningFromIt() throws {
      try makeBundle("Current")
      let beside = applications.appendingPathComponent("Current.app-other/Contents/MacOS/app").path

      XCTAssertEqual(retirement(running: [beside]).run()["Current.app"], .removed)
    }

    func testKeepsSomethingThatIsNotABundle() throws {
      try Data().write(to: applications.appendingPathComponent("Current.app"))
      try FileManager.default.createDirectory(
        at: applications.appendingPathComponent("Legacy.app"), withIntermediateDirectories: true)

      XCTAssertEqual(
        retirement().run(), ["Current.app": .keptNotABundle, "Legacy.app": .keptNotABundle])
    }

    func testOnlyLooksAtTheFixedNames() throws {
      try makeBundle("Unrelated")

      _ = retirement().run()

      XCTAssertTrue(exists("Unrelated.app"))
    }

    func testRunningExecutablePathsIncludesThisProcess() {
      let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
      let paths = PackageInstalledAppRetirement.runningExecutablePaths()
      XCTAssertFalse(paths.isEmpty)
      XCTAssertTrue(
        paths.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == own },
        "\(own) not among \(paths.count) processes")
    }

    // MARK: Fixtures

    private func retirement(
      packageOwner: uid_t = getuid(), running: [String] = []
    ) -> PackageInstalledAppRetirement {
      PackageInstalledAppRetirement(
        applicationsDirectory: applications,
        appNames: ["Current", "Legacy"],
        bundleIdentifier: "com.example.installer",
        packageOwner: packageOwner,
        runningExecutablePaths: { running })
    }

    private func makeBundle(_ name: String, identifier: String = "com.example.installer") throws {
      let contents = applications.appendingPathComponent("\(name).app/Contents", isDirectory: true)
      try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
      try info.write(to: contents.appendingPathComponent("Info.plist"))
      try Data().write(to: contents.appendingPathComponent("MacOS/app"))
    }

    private func exists(_ name: String) -> Bool {
      var status = stat()
      return lstat(applications.appendingPathComponent(name).path, &status) == 0
    }
  }
#endif
