#if os(macOS)
  import Darwin
  import Foundation
  import OpenDirectory

  enum RemovalStartupTool: Sendable {
    case blessGetBoot
    case nvramPrint
  }

  /// All executable paths and verbs are fixed here, never supplied by the XPC peer.
  struct MacRemovalDiskOperator: RemovalDiskOperating {
    var commands: @Sendable ([String]) throws -> Data = {
      try Self.systemRun("/usr/sbin/diskutil", $0)
    }
    var targetType: @Sendable () throws -> String = {
      try SysctlHardwarePropertyReader().string(named: "hw.targettype")
    }
    var startupTools: @Sendable (RemovalStartupTool) throws -> Data = { tool in
      switch tool {
      case .blessGetBoot: try Self.systemRun("/usr/sbin/bless", ["--getBoot"])
      case .nvramPrint: try Self.systemRun("/usr/sbin/nvram", ["-p"])
      }
    }
    var openTree: @Sendable (_ mountPoint: String, _ device: String) throws -> RemovalFileTree = {
      try RemovalFileTree(mountPoint: $0, device: $1)
    }
    var makeMountPoint: @Sendable () throws -> URL = Self.privateMountPoint

    func snapshot() throws -> RemovalSnapshot {
      let target = try targetType().lowercased()
      guard target != "j614s", target != "apple,j614s" else {
        throw RemovalFailure(message: "Removal is not supported on this Mac model.")
      }
      let root = try plist(["info", "-plist", "/"])
      guard root["Internal"] as? Bool == true,
        let stores = root["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
        let store = stores.first?["APFSPhysicalStore"] as? String,
        let rootReference = root["APFSContainerReference"] as? String
      else { throw invalid() }
      let physical = try plist(["info", "-plist", store])
      let disk = try string(physical, "ParentWholeDisk")
      let diskInfo = try plist(["info", "-plist", disk])
      guard diskInfo["Internal"] as? Bool == true,
        diskInfo["WholeDisk"] as? Bool == true,
        ["Physical", "Unknown"].contains(diskInfo["VirtualOrPhysical"] as? String ?? ""),
        diskInfo["Content"] as? String == "GUID_partition_scheme"
      else { throw invalid() }
      // Apple NVMe disks can report VirtualOrPhysical=Unknown in `info`.
      // Require membership in diskutil's independent internal/physical listing;
      // never infer that Unknown alone means a physical disk.
      let list = try plist(["list", "-plist", "internal", "physical"])
      guard let whole = list["AllDisksAndPartitions"] as? [[String: Any]],
        whole.filter({ $0["DeviceIdentifier"] as? String == disk }).count == 1,
        let entry = whole.first(where: { $0["DeviceIdentifier"] as? String == disk }),
        entry["Content"] as? String == "GUID_partition_scheme",
        let records = entry["Partitions"] as? [[String: Any]], records.count <= 32
      else { throw invalid() }
      let parts = try records.map { item -> RemovalPartition in
        let info = try plist(["info", "-plist", try string(item, "DeviceIdentifier")])
        guard try string(info, "ParentWholeDisk") == disk else { throw invalid() }
        let offset = try number(info, "PartitionMapPartitionOffset")
        let size = try number(info, "Size")
        guard size > 0, !offset.addingReportingOverflow(size).overflow else { throw invalid() }
        return RemovalPartition(
          identifier: try string(info, "DeviceIdentifier"), uuid: try uuid(info, "DiskUUID"),
          type: try string(info, "Content"), offset: offset, size: size,
          name: info["VolumeName"] as? String ?? "")
      }.sorted { $0.offset < $1.offset }
      let groups = try volumeGroups()
      let apfs = try plist(["apfs", "list", "-plist"])
      guard let rawContainers = apfs["Containers"] as? [[String: Any]] else { throw invalid() }
      var containers = [RemovalContainer]()
      var rootUUID: String?
      for raw in rawContainers {
        guard let physicalStores = raw["PhysicalStores"] as? [[String: Any]] else {
          throw invalid()
        }
        let matching = physicalStores.compactMap { item in
          parts.first { $0.identifier == item["DeviceIdentifier"] as? String }
        }
        if matching.isEmpty { continue }
        guard matching.count == 1, physicalStores.count == 1,
          let volumes = raw["Volumes"] as? [[String: Any]]
        else { throw invalid() }
        let parsed = try volumes.map { item -> RemovalVolume in
          guard let roles = item["Roles"] as? [String] else { throw invalid() }
          let volumeUUID = try uuid(item, "APFSVolumeUUID")
          return RemovalVolume(
            uuid: volumeUUID, name: try string(item, "Name"), roles: roles.sorted(),
            group: groups[volumeUUID], identifier: try string(item, "DeviceIdentifier"))
        }.sorted { $0.uuid < $1.uuid }
        let containerUUID = try uuid(raw, "APFSContainerUUID")
        if raw["ContainerReference"] as? String == rootReference { rootUUID = containerUUID }
        containers.append(
          RemovalContainer(uuid: containerUUID, storeUUID: matching[0].uuid, volumes: parsed))
      }
      guard let rootUUID else { throw invalid() }
      return RemovalSnapshot(
        disk: disk, devicePath: try string(diskInfo, "DeviceTreePath"),
        diskSize: try number(diskInfo, "Size"), macOSStoreUUID: try uuid(physical, "DiskUUID"),
        macOSContainerUUID: rootUUID, partitions: parts,
        containers: containers.sorted { $0.uuid < $1.uuid })
    }

    /// Volume UUID → volume-group UUID. A volume listed in two groups is invalid.
    private func volumeGroups() throws -> [String: String] {
      let listing = try plist(["apfs", "listVolumeGroups", "-plist"])
      guard let containers = listing["Containers"] as? [[String: Any]] else { throw invalid() }
      var result = [String: String]()
      for container in containers {
        for group in container["VolumeGroups"] as? [[String: Any]] ?? [] {
          let groupUUID = try uuid(group, "APFSVolumeGroupUUID")
          guard let volumes = group["Volumes"] as? [[String: Any]] else { throw invalid() }
          for volume in volumes {
            let volumeUUID = try uuid(volume, "DiskUUID")
            guard result.updateValue(groupUUID, forKey: volumeUUID) == nil else {
              throw invalid()
            }
          }
        }
      }
      return result
    }

    func evidence(for installation: RemovalInstallation, disk: String) throws -> RemovalEvidence {
      let esp = try withVolume(installation.esp.identifier, uuid: installation.esp.uuid) { info in
        try string(info, "ParentWholeDisk") == disk && info["Content"] as? String == "EFI"
      } read: { tree in
        (
          try tree.read(["m1n1", "boot.bin"], limit: 64 << 20),
          try tree.read(["asahi", "stub_info.json"], limit: 1 << 20),
          try tree.read(["asahi", "installer.log"], limit: 32 << 20)
        )
      }
      let stub = try withVolume(installation.system.identifier, uuid: installation.system.uuid) {
        info in
        let stores = (info["APFSPhysicalStores"] as? [[String: Any]])?.compactMap {
          $0["APFSPhysicalStore"] as? String
        }
        return stores == [installation.stub.identifier]
      } read: { tree in
        (
          try tree.exists("Library"),
          try tree.read(
            ["Finish Installation.app", "Contents", "Resources", "boot.bin"], limit: 64 << 20)
        )
      }
      return RemovalEvidence(
        files: RemovalInstallFiles(
          espBootObject: esp.0, stubInfo: esp.1, installerLog: esp.2, stubHasLibrary: stub.0,
          stubBootObject: stub.1))
    }

    /// Reads a volume in place when macOS already mounted it, otherwise mounts it
    /// read-only at a private directory and unmounts it again. The volume must be
    /// the one the approved snapshot names, by BSD identifier and UUID.
    private func withVolume<T>(
      _ identifier: String, uuid expected: String, belongs: ([String: Any]) throws -> Bool,
      read body: (RemovalFileTree) throws -> T
    ) throws -> T {
      let info = try plist(["info", "-plist", identifier])
      guard try string(info, "DeviceIdentifier") == identifier,
        try uuid(info, "DiskUUID") == expected, try belongs(info)
      else { throw RemovalFailure(message: "\(identifier) isn’t the volume that was reviewed.") }
      if let mounted = info["MountPoint"] as? String, !mounted.isEmpty {
        return try body(openTree(mounted, identifier))
      }
      let directory = try makeMountPoint()
      let path = directory.resolvingSymlinksInPath().path
      do {
        _ = try run(["mount", "readOnly", "nobrowse", "-mountPoint", path, identifier])
      } catch {
        if (try? plist(["info", "-plist", identifier]))?["MountPoint"] as? String == path {
          _ = try? run(["unmount", identifier])
        }
        _ = Darwin.rmdir(path)
        throw RemovalFailure(message: "\(identifier) couldn’t be mounted read-only.")
      }
      let result = Result<T, any Error>(catching: {
        let mounted = try plist(["info", "-plist", identifier])
        guard let actual = mounted["MountPoint"] as? String,
          URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == path,
          mounted["WritableVolume"] as? Bool == false
        else { throw RemovalFailure(message: "\(identifier) wasn’t mounted read-only.") }
        return try body(openTree(path, identifier))
      })
      do { _ = try run(["unmount", identifier]) } catch {
        throw RemovalFailure(message: "\(identifier) couldn’t be unmounted after checking it.")
      }
      _ = Darwin.rmdir(path)
      return try result.get()
    }

    func startup(_ snapshot: RemovalSnapshot) throws -> RemovalStartup {
      guard let variables = try? startupTools(.nvramPrint) else { return .unknown }
      let names = String(decoding: variables, as: UTF8.self).split(whereSeparator: \.isNewline)
        .map { $0.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? "" }
      if names.contains("alt-boot-volume") { return .nextStartupOverride }
      guard let raw = try? startupTools(.blessGetBoot) else { return .unknown }
      let device = String(decoding: raw, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard device.hasPrefix("/dev/disk"), !device.contains(" ") else { return .unknown }
      let identifier = String(device.dropFirst(5))
      guard let info = try? plist(["info", "-plist", identifier]),
        let stores = info["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
        let store = stores[0]["APFSPhysicalStore"] as? String,
        let storeInfo = try? plist(["info", "-plist", store]),
        let storeUUID = try? uuid(storeInfo, "DiskUUID"),
        let parent = try? string(storeInfo, "ParentWholeDisk")
      else { return .unknown }
      if storeUUID == snapshot.macOSStoreUUID, parent == snapshot.disk { return .macOS }
      let name = info["VolumeName"] as? String ?? ""
      return .other(name.isEmpty ? identifier : name)
    }

    func growLimit(_ macOS: RemovalPartition, disk: String) throws -> UInt64 {
      try requireIdentity(macOS, disk: disk)
      let limits = try plist(["apfs", "resizeContainer", macOS.identifier, "limits", "-plist"])
      return try number(limits, "MaximumSize")
    }

    func deleteContainer(_ stub: RemovalPartition, disk: String) throws {
      try requireIdentity(stub, disk: disk)
      try mutate(["apfs", "deleteContainer", stub.identifier])
    }
    func erasePartition(_ partition: RemovalPartition, disk: String) throws {
      try requireIdentity(partition, disk: disk)
      try mutate(["eraseVolume", "free", "none", partition.identifier])
    }
    func growContainer(_ macOS: RemovalPartition, disk: String) throws {
      try requireIdentity(macOS, disk: disk)
      try mutate(["apfs", "resizeContainer", macOS.identifier, "0"])
    }

    /// Commands take the BSD identifier from the snapshot just validated, after
    /// proving it is still that partition on that disk. A UUID argument could
    /// resolve to an attached clone.
    private func requireIdentity(_ part: RemovalPartition, disk: String) throws {
      let info = try plist(["info", "-plist", part.identifier])
      guard try string(info, "DeviceIdentifier") == part.identifier,
        try uuid(info, "DiskUUID") == part.uuid, try string(info, "ParentWholeDisk") == disk,
        try number(info, "PartitionMapPartitionOffset") == part.offset,
        try number(info, "Size") == part.size
      else { throw RemovalFailure(message: "The disk identity changed. Removal stopped.") }
    }

    private func mutate(_ arguments: [String]) throws { _ = try run(arguments) }
    private func plist(_ arguments: [String]) throws -> [String: Any] {
      guard
        let value = try PropertyListSerialization.propertyList(from: run(arguments), format: nil)
          as? [String: Any]
      else { throw invalid() }
      return value
    }
    private func run(_ arguments: [String]) throws -> Data { try commands(arguments) }

    static func systemRun(_ executable: String, _ arguments: [String]) throws -> Data {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      try process.run()
      let result = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw RemovalFailure(
          message:
            "macOS could not complete the disk operation (code \(process.terminationStatus)).")
      }
      guard result.count <= 8 * 1_024 * 1_024 else {
        throw RemovalFailure(message: "The disk response was too large.")
      }
      return result
    }
    static func privateMountPoint() throws -> URL {
      var template = Array(
        FileManager.default.temporaryDirectory.appendingPathComponent("omarchy-removal-XXXXXX")
          .path.utf8CString)
      guard let created = mkdtemp(&template) else {
        throw RemovalFailure(
          message: "A private folder for checking the installation couldn’t be made.")
      }
      return URL(fileURLWithPath: String(cString: created), isDirectory: true)
    }
    private func string(_ value: [String: Any], _ key: String) throws -> String {
      guard let result = value[key] as? String, !result.isEmpty else { throw invalid() }
      return result
    }
    private func uuid(_ value: [String: Any], _ key: String) throws -> String {
      guard let result = UUID(uuidString: try string(value, key)) else { throw invalid() }
      return result.uuidString
    }
    private func number(_ value: [String: Any], _ key: String) throws -> UInt64 {
      guard let result = value[key] as? NSNumber, result.int64Value >= 0 else { throw invalid() }
      return result.uint64Value
    }
    private func invalid() -> RemovalFailure {
      RemovalFailure(
        message: "The internal macOS disk layout could not be verified.")
    }
  }

  /// Read-only access below one mount root: every component is opened with
  /// O_NOFOLLOW and must stay on the root's device, so a link can't lead the
  /// helper elsewhere. Only ENOENT counts as "absent".
  final class RemovalFileTree: @unchecked Sendable {
    private let root: Int32
    private let device: dev_t

    /// Opens a mount root and proves it is the root of `device`'s mount.
    convenience init(mountPoint: String, device: String) throws {
      guard let resolved = realpath(mountPoint, nil) else { throw Self.failure(mountPoint) }
      let path = String(cString: resolved)
      free(resolved)
      let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw Self.failure(path) }
      var filesystem = statfs()
      var opened = stat()
      var named = stat()
      guard fstatfs(descriptor, &filesystem) == 0, fstat(descriptor, &opened) == 0,
        Self.text(&filesystem.f_mntfromname) == "/dev/\(device)",
        Self.text(&filesystem.f_mntonname) == path,
        lstat(path, &named) == 0, named.st_dev == opened.st_dev, named.st_ino == opened.st_ino
      else {
        close(descriptor)
        throw RemovalFailure(message: "\(device) isn’t mounted where macOS reported it.")
      }
      try self.init(descriptor: descriptor)
    }

    /// Takes ownership of an open directory descriptor.
    init(descriptor: Int32) throws {
      var info = stat()
      guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
        close(descriptor)
        throw RemovalFailure(message: "A checked volume couldn’t be opened.")
      }
      root = descriptor
      device = info.st_dev
    }

    deinit { close(root) }

    func exists(_ name: String) throws -> Bool {
      var info = stat()
      if fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
      guard errno == ENOENT else { throw Self.failure(name) }
      return false
    }

    func read(_ components: [String], limit: Int) throws -> Data? {
      let path = components.joined(separator: "/")
      var directory = dup(root)
      guard directory >= 0 else { throw Self.failure(path) }
      defer { close(directory) }
      for (index, component) in components.enumerated() {
        let last = index == components.count - 1
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY)
        let next = openat(directory, component, flags)
        if next < 0 {
          if errno == ENOENT { return nil }
          throw Self.failure(path)
        }
        var info = stat()
        guard fstat(next, &info) == 0, info.st_dev == device,
          (info.st_mode & S_IFMT) == (last ? S_IFREG : S_IFDIR)
        else {
          close(next)
          throw Self.failure(path)
        }
        if !last {
          close(directory)
          directory = next
          continue
        }
        defer { close(next) }
        guard info.st_size >= 0, info.st_size <= off_t(limit) else { throw Self.failure(path) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
          let count = Darwin.read(next, &buffer, buffer.count)
          guard count >= 0 else { throw Self.failure(path) }
          if count == 0 { break }
          data.append(buffer, count: count)
          guard data.count <= limit else { throw Self.failure(path) }
        }
        return data
      }
      return nil
    }

    private static func failure(_ path: String) -> RemovalFailure {
      RemovalFailure(message: "\(path) couldn’t be read safely.")
    }

    private static func text<T>(_ value: inout T) -> String {
      withUnsafeBytes(of: &value) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
    }
  }

  func requireRemovalAdministrator(_ authorization: MachineOwnerAuthorization) throws {
    let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
    let user = try node.record(
      withRecordType: kODRecordTypeUsers, name: authorization.username, attributes: nil)
    let admin = try node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: nil)
    do { try admin.isMemberRecord(user) } catch {
      throw RemovalFailure(message: "Use a macOS administrator account to remove Omarchy.")
    }
  }
#endif
