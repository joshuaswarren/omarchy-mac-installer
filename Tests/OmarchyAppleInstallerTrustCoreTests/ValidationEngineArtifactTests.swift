#if os(macOS)
  import Foundation
  import XCTest

  @testable import OmarchyAppleInstallerTrustCore

  final class ValidationEngineArtifactTests: XCTestCase {
    func testM3CapableInspectionIdentityIsPinnedExactly() {
      XCTAssertEqual(
        ValidationEngineArtifactLocator.version,
        "v0.9.2-omarchy.19"
      )
      XCTAssertEqual(
        ValidationEngineArtifactLocator.fileName,
        "installer-v0.9.2-omarchy.19.tar.gz"
      )
      XCTAssertEqual(
        ValidationEngineArtifactLocator.expectedDigest,
        "sha256:4bb3a429a2678a22b48b7c0e00b4f207beb0949d85d424be669477e0ca483745"
      )
      XCTAssertEqual(
        ValidationEngineArtifactLocator.expectedSizeBytes,
        17_839_390
      )
    }

    func testEnvironmentOverrideSelectsExactValidationArtifactIdentity()
      throws
    {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let archive = root.appendingPathComponent("engine.tar.gz")
      XCTAssertTrue(
        FileManager.default.createFile(
          atPath: archive.path,
          contents: Data("fixture".utf8)
        ))

      let result = try ValidationEngineArtifactLocator().locate(
        environment: ["OMARCHY_VALIDATION_ENGINE_ARCHIVE": archive.path],
        currentDirectory: root,
        resourceDirectory: nil
      )

      XCTAssertEqual(result.fileURL, archive)
      XCTAssertEqual(
        result.expectedDigest,
        ValidationEngineArtifactLocator.expectedDigest
      )
      XCTAssertEqual(
        result.expectedSizeBytes,
        ValidationEngineArtifactLocator.expectedSizeBytes
      )
    }

    func testMissingValidationArtifactFailsClosed() throws {
      let root = try makeDirectory()
      defer { try? FileManager.default.removeItem(at: root) }

      XCTAssertThrowsError(
        try ValidationEngineArtifactLocator().locate(
          environment: [:],
          currentDirectory: root,
          resourceDirectory: nil
        )
      ) {
        XCTAssertEqual(
          $0 as? ValidationEngineArtifactError,
          .unavailable
        )
      }
    }

    private func makeDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "omarchy-validation-artifact-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      return root
    }
  }
#endif
