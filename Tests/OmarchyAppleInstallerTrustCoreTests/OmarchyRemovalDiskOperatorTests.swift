#if os(macOS)
  import Darwin
  import Foundation
  import XCTest
  @testable import OmarchyAppleInstallerTrustCore

  final class OmarchyRemovalDiskOperatorTests: XCTestCase {
    typealias F = RemovalFixtures

    func testNativePlistParserMatchesTheModelAndUsesFixedCommands() throws {
      for model in [F.converged(), F.alarm(), F.fedora(), F.freeSpaceOnly(), F.windows()] {
        let disk = FakeDiskutil(model).makeOperator()
        XCTAssertEqual(try disk.snapshot(), model)
      }
    }

    func testOlderInstallIsPlannedEndToEndFromDiskutilAndFilesReadInPlace() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let esp = try temporaryDirectory()
      let stub = try temporaryDirectory()
      defer {
        try? FileManager.default.removeItem(at: esp)
        try? FileManager.default.removeItem(at: stub)
      }
      try write(F.files(for: F.alarmInstall, in: model), esp: esp, stub: stub)
      fake.mountPoints = ["disk0s4": esp.path, "disk4s2": stub.path]
      let plan = try OmarchyRemovalPlan(disks: fake.makeOperator())
      XCTAssertEqual(plan.installation?.name, "Asahi Alarm Minimal")
      XCTAssertEqual(plan.reclaimBytes, 32_800_505_856)
      XCTAssertTrue(
        fake.log.allSatisfy {
          $0[0] == "info" || $0[0] == "list"
            || ($0[0] == "apfs" && ["list", "listVolumeGroups"].contains($0[1]))
        }, "\(fake.log)")
    }

    func testUnmountedVolumesAreMountedReadOnlyPrivatelyAndUnmountedAgain() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let files = F.files(for: F.alarmInstall, in: model)
      fake.onMount = { identifier, path in
        let root = URL(fileURLWithPath: path)
        if identifier == "disk0s4" {
          try self.write(files, esp: root, stub: nil)
        } else {
          try self.write(files, esp: nil, stub: root)
        }
      }
      let plan = try OmarchyRemovalPlan(disks: fake.makeOperator())
      XCTAssertEqual(plan.members.count, 3)
      let mounts = fake.log.filter { $0.first == "mount" }
      XCTAssertEqual(
        mounts.map { Array($0.prefix(3)) },
        [["mount", "readOnly", "nobrowse"], ["mount", "readOnly", "nobrowse"]])
      XCTAssertEqual(mounts.map(\.last), ["disk0s4", "disk4s2"])
      XCTAssertEqual(
        fake.log.filter { $0.first == "unmount" },
        [["unmount", "disk0s4"], ["unmount", "disk4s2"]])
      for path in fake.createdMountPoints {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
      }
    }

    func testDirtyEFIPartitionIsMountedReadOnlyWithoutDiskArbitrationsCheck() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let files = F.files(for: F.alarmInstall, in: model)
      fake.onMount = { identifier, path in
        let root = URL(fileURLWithPath: path)
        if identifier == "disk0s4" {
          try self.write(files, esp: root, stub: nil)
        } else {
          try self.write(files, esp: nil, stub: root)
        }
      }
      fake.refuseDiskutilMount = ["disk0s4"]
      let plan = try OmarchyRemovalPlan(disks: fake.makeOperator())
      XCTAssertEqual(plan.members.count, 3)
      let mounts = fake.log.filter { ["mount", "fatMount"].contains($0.first) }
      XCTAssertEqual(mounts.map { [$0.first!, $0.last!] }.count, 3)
      XCTAssertEqual(mounts[0].first, "mount")
      XCTAssertEqual(mounts[0].last, "disk0s4")
      XCTAssertEqual(Array(mounts[1].prefix(2)), ["fatMount", "disk0s4"])
      XCTAssertEqual(mounts[1][2], mounts[0][mounts[0].count - 2], "same private mount point")
      XCTAssertEqual(mounts[2].first, "mount")
      XCTAssertEqual(mounts[2].last, "disk4s2")
      XCTAssertEqual(
        fake.log.filter { $0.first == "unmount" },
        [["unmount", "disk0s4"], ["unmount", "disk4s2"]])
      for path in fake.createdMountPoints {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
      }
    }

    func testFATFallbackIsOnlyForTheEFIPartitionAndStillMustBeReadOnly() throws {
      let model = F.alarm()
      let files = F.files(for: F.alarmInstall, in: model)
      func attempt(_ configure: (FakeDiskutil) -> Void) -> (FakeDiskutil, String) {
        let fake = FakeDiskutil(model)
        fake.onMount = { identifier, path in
          let root = URL(fileURLWithPath: path)
          if identifier == "disk0s4" {
            try self.write(files, esp: root, stub: nil)
          } else {
            try self.write(files, esp: nil, stub: root)
          }
        }
        configure(fake)
        var message = ""
        XCTAssertThrowsError(try OmarchyRemovalPlan(disks: fake.makeOperator())) { error in
          message = (error as? RemovalFailure)?.message ?? ""
        }
        return (fake, message)
      }
      let (stub, stubMessage) = attempt { $0.refuseDiskutilMount = ["disk4s2"] }
      XCTAssertFalse(stub.log.contains { $0.first == "fatMount" })
      XCTAssertTrue(stubMessage.contains("disk4s2 couldn’t be mounted read-only"), stubMessage)
      let (both, bothMessage) = attempt {
        $0.refuseDiskutilMount = ["disk0s4"]
        $0.refuseFATMount = true
      }
      XCTAssertEqual(both.log.filter { $0.first == "fatMount" }.count, 1)
      XCTAssertTrue(bothMessage.contains("disk0s4 couldn’t be mounted read-only"), bothMessage)
      for path in both.createdMountPoints {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
      }
      let (writable, writableMessage) = attempt {
        $0.refuseDiskutilMount = ["disk0s4"]
        $0.mountWritable = true
      }
      XCTAssertTrue(writableMessage.contains("disk0s4 wasn’t mounted read-only"), writableMessage)
      XCTAssertEqual(writable.log.filter { $0.first == "unmount" }, [["unmount", "disk0s4"]])
    }

    func testWritableMountOrFailedUnmountRefuses() throws {
      let model = F.alarm()
      for failure in ["writable", "unmount"] {
        let fake = FakeDiskutil(model)
        let files = F.files(for: F.alarmInstall, in: model)
        fake.onMount = { identifier, path in
          try self.write(files, esp: URL(fileURLWithPath: path), stub: nil)
        }
        if failure == "writable" { fake.mountWritable = true } else { fake.failUnmount = true }
        XCTAssertThrowsError(try OmarchyRemovalPlan(disks: fake.makeOperator())) { error in
          let message = (error as? RemovalFailure)?.message ?? ""
          XCTAssertTrue(message.contains("its files couldn’t be checked: disk0s4"), message)
        }
        XCTAssertEqual(fake.log.filter { $0.first == "unmount" }.count, 1)
      }
    }

    func testEvidenceIsReadOnlyFromTheReviewedDevice() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let disk = fake.makeOperator()
      guard case .installation(let found, _, _) = try RemovalLayout.recognize(model) else {
        return XCTFail("installation expected")
      }
      let esp = found.esp
      let clone = RemovalInstallation(
        name: found.name, stub: found.stub, system: found.system,
        esp: RemovalPartition(
          identifier: esp.identifier, uuid: F.id(99), type: esp.type, offset: esp.offset,
          size: esp.size, name: esp.name), linux: found.linux)
      XCTAssertThrowsError(try disk.evidence(for: clone, disk: "disk0")) { error in
        XCTAssertEqual(
          (error as? RemovalFailure)?.message, "disk0s4 isn’t the volume that was reviewed.")
      }
      let otherStore = RemovalInstallation(
        name: found.name, stub: found.linux[0], system: found.system, esp: found.esp,
        linux: [])
      fake.onMount = { _, _ in }
      XCTAssertThrowsError(try disk.evidence(for: otherStore, disk: "disk0")) { error in
        XCTAssertEqual(
          (error as? RemovalFailure)?.message, "disk4s2 isn’t the volume that was reviewed.")
      }
      XCTAssertThrowsError(try disk.evidence(for: found, disk: "disk7"))
    }

    func testStartupIsReadFromBlessAndNVRAM() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let disk = fake.makeOperator()
      let macOS = F.bootVolume(store: model.macOSStoreUUID, group: F.macGroup)
      let stub = F.bootVolume(store: F.alarmInstall.stub, group: F.alarmInstall.group)
      XCTAssertEqual(try disk.startup(model), .macOS)
      fake.nvram = "auto-boot\ttrue\nboot-volume\t\(macOS)\nalt-boot-volume\t\(stub)\n"
      XCTAssertEqual(try disk.startup(model), .nextStartupOverride)
      fake.nvram =
        "boot-volume\t\(macOS)\nalt-boot-volume\tEF57347C-0000-AA11-AA11-00306543ECAC:X\n"
      XCTAssertEqual(try disk.startup(model), .nextStartupOverride)
      fake.nvram = "boot-volume\t\(macOS)\nalt-boot-volume\t\(macOS)\nalt-boot-volume\t\(macOS)\n"
      XCTAssertEqual(try disk.startup(model), .nextStartupOverride, "listed twice")
      fake.nvram = "boot-volume\t\(stub)\nalt-boot-volume\t\(macOS)\n"
      XCTAssertEqual(
        try disk.startup(model), .nextStartupOverride,
        "a one-time macOS choice doesn’t hide a startup disk that is about to be deleted")
      fake.nvram = "boot-volume\t\(macOS)\nalt-boot-volume\t\(macOS)\n"
      XCTAssertEqual(try disk.startup(model), .macOS, "both choices name the running macOS")
      fake.nvram = "boot-volume\t\(F.bootVolume(store: model.macOSStoreUUID, group: F.id(1)))\n"
      XCTAssertEqual(try disk.startup(model), .unknown, "another macOS in the same container")
      fake.nvram = "boot-volume\tgarbage\n"
      XCTAssertEqual(try disk.startup(model), .unknown)
      fake.nvram = "auto-boot\ttrue\n"
      XCTAssertEqual(try disk.startup(model), .macOS)
      fake.bless = "/dev/disk4s2\n"
      XCTAssertEqual(try disk.startup(model), .other("Asahi Alarm Minimal"))
      fake.bless = nil
      XCTAssertEqual(try disk.startup(model), .unknown)
      fake.bless = "garbage"
      XCTAssertEqual(try disk.startup(model), .unknown)
      fake.bless = "/dev/disk3s1\n"
      fake.rootGroup = nil
      XCTAssertEqual(try disk.startup(model), .unknown)
      fake.rootGroup = F.id(1)
      XCTAssertEqual(try disk.startup(model), .unknown, "the startup volume isn’t the running one")
    }

    func testBootTargetReadsThePartitionGUIDAsNVRAMStoresIt() {
      // boot-volume on the M1 Pro lab Mac (macOS 27.0, 2026-09-28): disk0s2 is
      // 1EDFBFBF-3123-4142-BF27-A7215B874733, its macOS group 3EE75828-….
      XCTAssertEqual(
        RemovalBootTarget(
          nvram:
            "EF57347C-0000-AA11-AA11-00306543ECAC:BFBFDF1E-2331-4241-BF27-A7215B874733:3EE75828-1F54-4365-9BA7-E7217E81D869"
        ),
        RemovalBootTarget(
          store: "1EDFBFBF-3123-4142-BF27-A7215B874733",
          group: "3EE75828-1F54-4365-9BA7-E7217E81D869"))
      for value in [
        "", "EF57347C-0000-AA11-AA11-00306543ECAC:X",
        "EF57347C-0000-AA11-AA11-00306543ECAC:BFBFDF1E-2331-4241-BF27-A7215B874733",
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B:BFBFDF1E-2331-4241-BF27-A7215B874733:3EE75828-1F54-4365-9BA7-E7217E81D869",
        "EF57347C-0000-AA11-AA11-00306543ECAC:BFBFDF1E-2331-4241-BF27-A7215B874733:3EE75828-1F54-4365-9BA7-E7217E81D869:x",
      ] {
        XCTAssertNil(RemovalBootTarget(nvram: value), value)
      }
    }

    func testStartupIsSetOnTheRunningMacOSWithTheOwnerPasswordOnStdin() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let disk = fake.makeOperator()
      let owner = try MachineOwnerAuthorization(
        username: "test-admin", password: Data("test-password".utf8))
      try disk.setMacOSStartup(model, nextOnly: false, authorization: owner)
      try disk.setMacOSStartup(model, nextOnly: true, authorization: owner)
      XCTAssertEqual(
        fake.blessed.map(\.arguments),
        [
          ["--mount", "/", "--setBoot", "--user", "test-admin", "--stdinpass"],
          ["--mount", "/", "--setBoot", "--nextonly", "--user", "test-admin", "--stdinpass"],
        ])
      XCTAssertEqual(
        fake.blessed.map(\.input), Array(repeating: Data("test-password\n".utf8), count: 2))
      fake.blessRefusal = "Failed to authenticate owner"
      XCTAssertThrowsError(try disk.setMacOSStartup(model, nextOnly: false, authorization: owner)) {
        XCTAssertEqual(($0 as? RemovalStartupRefusal)?.reason, "Failed to authenticate owner")
      }
      XCTAssertTrue(fake.log.allSatisfy { !$0.contains("--setBoot") })
    }

    func testStartupIsNeverSetWhenTheRunningSystemIsntThisMacOS() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let owner = try MachineOwnerAuthorization(
        username: "test-admin", password: Data("test-password".utf8))
      fake.override["info -plist /"] = [
        "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s3"]]
      ]
      XCTAssertThrowsError(
        try fake.makeOperator().setMacOSStartup(model, nextOnly: false, authorization: owner)
      ) {
        XCTAssertEqual(
          ($0 as? RemovalFailure)?.message,
          "The running macOS isn’t the one removal returns the space to.")
      }
      XCTAssertTrue(fake.blessed.isEmpty)
    }

    func testBlessRunnerQuotesItsLastLineWithoutThePassword() throws {
      XCTAssertNoThrow(
        try MacRemovalDiskOperator.runBless(
          ["-c", "read line; [ \"$line\" = secret ]"], input: Data("secret\n".utf8),
          secret: Data("secret".utf8), executable: "/bin/sh"))
      XCTAssertThrowsError(
        try MacRemovalDiskOperator.runBless(
          ["-c", "read line; echo start; echo \"Failed for $line\" >&2; echo; exit 3"],
          input: Data("secret\n".utf8), secret: Data("secret".utf8), executable: "/bin/sh")
      ) { error in
        let reason = (error as? RemovalStartupRefusal)?.reason ?? ""
        XCTAssertTrue(reason.hasPrefix("Failed for"), reason)
        XCTAssertFalse(reason.contains("secret"), reason)
      }
      XCTAssertThrowsError(
        try MacRemovalDiskOperator.runBless(
          ["-c", "exit 4"], input: Data("secret\n".utf8), secret: Data("secret".utf8),
          executable: "/bin/sh")
      ) { error in
        XCTAssertEqual((error as? RemovalStartupRefusal)?.reason, "bless stopped with code 4")
      }
    }

    func testMutationsUseTheValidatedBSDIdentifierOnlyAfterProvingIdentity() throws {
      let model = F.alarm()
      let fake = FakeDiskutil(model)
      let disk = fake.makeOperator()
      try disk.deleteContainer(model.partitions[2], disk: "disk0")
      try disk.erasePartition(model.partitions[3], disk: "disk0")
      try disk.growContainer(model.partitions[1], disk: "disk0")
      XCTAssertEqual(
        fake.log.filter { $0.first != "info" },
        [
          ["apfs", "deleteContainer", "disk0s3"], ["eraseVolume", "free", "none", "disk0s4"],
          ["apfs", "resizeContainer", "disk0s2", "0"],
        ])
      fake.log = []
      fake.override["info -plist disk0s4"] = ["DiskUUID": F.id(98)]
      XCTAssertThrowsError(try disk.erasePartition(model.partitions[3], disk: "disk0"))
      XCTAssertThrowsError(try disk.deleteContainer(model.partitions[2], disk: "disk9"))
      XCTAssertEqual(fake.log.filter { $0.first != "info" }, [])
    }

    func testGrowLimitReadsResizeLimits() throws {
      let model = F.freeSpaceOnly()
      let fake = FakeDiskutil(model)
      XCTAssertEqual(
        try fake.makeOperator().growLimit(model.partitions[1], disk: "disk0"), 494_384_793_600)
      XCTAssertEqual(fake.log.last, ["apfs", "resizeContainer", "disk0s2", "limits", "-plist"])
    }

    func testM4RejectedBeforeDiskCommands() {
      let disk = MacRemovalDiskOperator(
        commands: { _ in
          XCTFail("No disk command expected")
          return Data()
        }, targetType: { "j614s" })
      XCTAssertThrowsError(try disk.snapshot())
    }

    func testNativeParserAcceptsAppleSSDReportedAsUnknownWhenListedPhysical() throws {
      let fake = FakeDiskutil(F.converged())
      fake.override["info -plist disk0"] = ["VirtualOrPhysical": "Unknown"]
      XCTAssertNoThrow(try fake.makeOperator().snapshot())
      fake.override["list -plist internal physical"] = ["AllDisksAndPartitions": [Any]()]
      XCTAssertThrowsError(try fake.makeOperator().snapshot())
    }

    func testExplicitlyVirtualDiskIsRejectedDespiteConflictingListing() {
      let fake = FakeDiskutil(F.converged())
      fake.override["info -plist disk0"] = ["VirtualOrPhysical": "Virtual"]
      XCTAssertThrowsError(try fake.makeOperator().snapshot())
    }

    func testNativeParserRejectsExternalAndMultiplePhysicalStores() {
      for root: [String: Any] in [
        ["Internal": false],
        [
          "APFSPhysicalStores": [
            ["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk9s2"],
          ]
        ],
      ] {
        let fake = FakeDiskutil(F.converged())
        fake.override["info -plist /"] = root
        XCTAssertThrowsError(try fake.makeOperator().snapshot())
      }
    }

    func testVolumeInTwoGroupsIsRejected() {
      let fake = FakeDiskutil(F.alarm())
      fake.duplicateGroupMembership = true
      XCTAssertThrowsError(try fake.makeOperator().snapshot())
    }

    // MARK: Safe file access

    func testFileTreeRefusesLinksAndOversizeAndReportsOnlyENOENTAsAbsent() throws {
      let root = try temporaryDirectory()
      defer {
        chmod(root.appendingPathComponent("locked").path, 0o755)
        try? FileManager.default.removeItem(at: root)
      }
      let manager = FileManager.default
      try manager.createDirectory(
        at: root.appendingPathComponent("asahi"), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: root.appendingPathComponent("asahi/stub_info.json"))
      try Data(count: 2048).write(to: root.appendingPathComponent("big"))
      try manager.createSymbolicLink(
        atPath: root.appendingPathComponent("linked").path, withDestinationPath: "asahi")
      try manager.createSymbolicLink(
        atPath: root.appendingPathComponent("Library").path, withDestinationPath: "missing")
      try manager.createDirectory(
        at: root.appendingPathComponent("locked"), withIntermediateDirectories: true)
      chmod(root.appendingPathComponent("locked").path, 0)
      let tree = try directoryTree(root)
      XCTAssertEqual(try tree.read(["asahi", "stub_info.json"], limit: 1024), Data("{}".utf8))
      XCTAssertNil(try tree.read(["asahi", "installer.log"], limit: 1024))
      XCTAssertNil(try tree.read(["nothing", "here"], limit: 1024))
      XCTAssertThrowsError(try tree.read(["linked", "stub_info.json"], limit: 1024))
      XCTAssertThrowsError(try tree.read(["big"], limit: 1024))
      XCTAssertThrowsError(try tree.read(["asahi"], limit: 1024))
      XCTAssertThrowsError(try tree.read(["locked", "file"], limit: 1024))
      XCTAssertTrue(try tree.exists("Library"))
      XCTAssertTrue(try tree.exists("asahi"))
      XCTAssertFalse(try tree.exists("System"))
    }

    func testMountRootMustBeTheReportedDevice() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      XCTAssertThrowsError(try RemovalFileTree(mountPoint: root.path, device: "disk0s4"))
    }

    // MARK: Helpers

    private func directoryTree(_ url: URL) throws -> RemovalFileTree {
      try RemovalFileTree(descriptor: open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW))
    }

    private func write(_ files: RemovalInstallFiles, esp: URL?, stub: URL?) throws {
      let manager = FileManager.default
      func put(_ data: Data?, _ root: URL, _ path: String) throws {
        guard let data else { return }
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
      }
      if let esp {
        try put(files.espBootObject, esp, "m1n1/boot.bin")
        try put(files.stubInfo, esp, "asahi/stub_info.json")
        try put(files.installerLog, esp, "asahi/installer.log")
      }
      if let stub {
        try put(
          files.stubBootObject, stub, "Finish Installation.app/Contents/Resources/boot.bin")
        try put(Data("stub".utf8), stub, "System/Library/CoreServices/SystemVersion.plist")
      }
    }

    private func temporaryDirectory() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "removal-operator-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return root.resolvingSymlinksInPath()
    }
  }

  /// Answers diskutil, bless and nvram from a model snapshot, in the key shapes
  /// those tools print on Apple silicon (`info -plist`, `list -plist`,
  /// `apfs list -plist`, `apfs listVolumeGroups -plist`).
  final class FakeDiskutil: @unchecked Sendable {
    let model: RemovalSnapshot
    var override = [String: [String: Any]]()
    var mountPoints = [String: String]()
    var onMount: ((String, String) throws -> Void)?
    var mountWritable = false
    var failUnmount = false
    /// `diskutil mount` refuses these, as it does a dirty FAT.
    var refuseDiskutilMount = Set<String>()
    var refuseFATMount = false
    var duplicateGroupMembership = false
    var nvram: String
    var bless: String? = "/dev/disk3s1\n"
    var rootGroup: String? = RemovalFixtures.macGroup
    var blessed = [(arguments: [String], input: Data)]()
    var blessRefusal: String?
    var log = [[String]]()
    var createdMountPoints = [String]()
    private let lock = NSLock()

    init(_ model: RemovalSnapshot) {
      self.model = model
      nvram =
        "auto-boot\ttrue\nboot-volume\t"
        + RemovalFixtures.bootVolume(store: model.macOSStoreUUID, group: RemovalFixtures.macGroup)
        + "\n"
    }

    func makeOperator() -> MacRemovalDiskOperator {
      MacRemovalDiskOperator(
        commands: { try self.run($0) }, targetType: { "j314s" },
        startupTools: { tool in
          switch tool {
          case .nvramPrint: return Data(self.nvram.utf8)
          case .blessGetBoot:
            guard let bless = self.bless else { throw RemovalFailure(message: "bless failed") }
            return Data(bless.utf8)
          }
        },
        blessSetBoot: { arguments, input, _ in
          self.lock.lock()
          defer { self.lock.unlock() }
          self.blessed.append((arguments, input))
          if let refusal = self.blessRefusal { throw RemovalStartupRefusal(reason: refusal) }
        },
        openTree: { path, _ in
          try RemovalFileTree(descriptor: open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW))
        },
        makeMountPoint: {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "removal-mount-\(UUID())")
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
          self.createdMountPoints.append(url.resolvingSymlinksInPath().path)
          return url
        },
        fatMount: { device, path in
          self.lock.lock()
          defer { self.lock.unlock() }
          self.log.append(["fatMount", device, path])
          if self.refuseFATMount { throw RemovalFailure(message: "mount_msdos failed") }
          try self.onMount?(device, path)
          self.mountPoints[device] = path
        })
    }

    func run(_ arguments: [String]) throws -> Data {
      lock.lock()
      defer { lock.unlock() }
      log.append(arguments)
      let key = arguments.joined(separator: " ")
      if arguments.first == "mount" {
        let identifier = arguments.last!
        let path = arguments[arguments.count - 2]
        if refuseDiskutilMount.contains(identifier) {
          throw RemovalFailure(message: "Volume on \(identifier) failed to mount")
        }
        try onMount?(identifier, path)
        mountPoints[identifier] = path
        return Data()
      }
      if arguments.first == "unmount" {
        if failUnmount { throw RemovalFailure(message: "busy") }
        if let path = mountPoints.removeValue(forKey: arguments[1]) {
          for item in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            try? FileManager.default.removeItem(atPath: path + "/" + item)
          }
        }
        return Data()
      }
      if ["deleteContainer", "eraseVolume"].contains(arguments.count > 1 ? arguments[1] : "")
        || arguments.first == "eraseVolume"
        || (arguments.count == 4 && arguments[1] == "resizeContainer")
      {
        return Data()
      }
      guard var object = response(arguments) else {
        throw RemovalFailure(message: "unexpected command \(key)")
      }
      for (name, value) in override[key] ?? [:] { object[name] = value }
      return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private func response(_ arguments: [String]) -> [String: Any]? {
      let key = arguments.joined(separator: " ")
      let macOS = model.partitions.first { $0.uuid == model.macOSStoreUUID }!
      switch key {
      case "info -plist /":
        var root: [String: Any] = [
          "Internal": true, "APFSContainerReference": "disk3",
          "APFSPhysicalStores": [["APFSPhysicalStore": macOS.identifier]],
        ]
        root["APFSVolumeGroupID"] = rootGroup
        return root
      case "info -plist \(model.disk)":
        return [
          "Internal": true, "WholeDisk": true, "VirtualOrPhysical": "Physical",
          "Content": "GUID_partition_scheme", "DeviceTreePath": model.devicePath,
          "Size": model.diskSize,
        ]
      case "list -plist internal physical":
        return [
          "AllDisksAndPartitions": [
            [
              "DeviceIdentifier": model.disk, "Content": "GUID_partition_scheme",
              "Partitions": model.partitions.map { ["DeviceIdentifier": $0.identifier] },
            ]
          ]
        ]
      case "apfs list -plist":
        return [
          "Containers": model.containers.map { container -> [String: Any] in
            let store = model.partitions.first { $0.uuid == container.storeUUID }!
            return [
              "ContainerReference": reference(container), "APFSContainerUUID": container.uuid,
              "PhysicalStores": [["DeviceIdentifier": store.identifier]],
              "Volumes": container.volumes.map {
                [
                  "APFSVolumeUUID": $0.uuid, "Name": $0.name, "Roles": $0.roles,
                  "DeviceIdentifier": $0.identifier,
                ]
              },
            ]
          }
        ]
      case "apfs listVolumeGroups -plist":
        return [
          "Containers": model.containers.map { container -> [String: Any] in
            let groups = Dictionary(grouping: container.volumes.filter { $0.group != nil }) {
              $0.group!
            }
            var listed = groups.map { group, volumes -> [String: Any] in
              [
                "APFSVolumeGroupUUID": group,
                "Volumes": volumes.map {
                  [
                    "DiskUUID": $0.uuid, "DeviceIdentifier": $0.identifier,
                    "Role": $0.roles.first ?? "",
                  ]
                },
              ]
            }
            if duplicateGroupMembership, let first = listed.first,
              container.uuid != model.macOSContainerUUID
            {
              var copy = first
              copy["APFSVolumeGroupUUID"] = RemovalFixtures.id(990)
              listed.append(copy)
            }
            return ["APFSContainerUUID": container.uuid, "VolumeGroups": listed]
          }
        ]
      default: break
      }
      if arguments.count == 5, arguments[1] == "resizeContainer", arguments[3] == "limits" {
        let part = model.partitions.first { $0.identifier == arguments[2] }!
        let next = model.partitions.filter { $0.offset > part.offset }.map(\.offset).min()!
        return ["CurrentSize": part.size, "MaximumSize": next - part.offset]
      }
      guard arguments.count == 3, arguments[0] == "info", arguments[1] == "-plist" else {
        return nil
      }
      let identifier = arguments[2]
      if let part = model.partitions.first(where: { $0.identifier == identifier }) {
        return [
          "DeviceIdentifier": part.identifier, "ParentWholeDisk": model.disk,
          "DiskUUID": part.uuid, "Content": part.type,
          "PartitionMapPartitionOffset": part.offset, "Size": part.size,
          "VolumeName": part.name, "MountPoint": mountPoints[identifier] ?? "",
          "WritableVolume": !mountWritable ? mountPoints[identifier] == nil : true,
        ]
      }
      for container in model.containers {
        guard let volume = container.volumes.first(where: { $0.identifier == identifier }) else {
          continue
        }
        let store = model.partitions.first { $0.uuid == container.storeUUID }!
        var info: [String: Any] = [
          "DeviceIdentifier": identifier, "DiskUUID": volume.uuid, "VolumeName": volume.name,
          "APFSPhysicalStores": [["APFSPhysicalStore": store.identifier]],
          "MountPoint": mountPoints[identifier] ?? "",
          "WritableVolume": !mountWritable ? mountPoints[identifier] == nil : true,
        ]
        info["APFSVolumeGroupID"] = volume.group
        return info
      }
      return nil
    }

    private func reference(_ container: RemovalContainer) -> String {
      if container.uuid == model.macOSContainerUUID { return "disk3" }
      guard let identifier = container.volumes.first?.identifier,
        let end = identifier.dropFirst(4).firstIndex(of: "s")
      else { return "disk9" }
      return String(identifier[..<end])
    }
  }
#endif
