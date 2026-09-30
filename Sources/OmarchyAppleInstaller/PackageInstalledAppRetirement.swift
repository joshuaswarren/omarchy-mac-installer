#if os(macOS)
  import Darwin
  import Foundation

  /// Removes the installer app that the installer package put in
  /// `/Applications`, under the current or the legacy name, once the app has
  /// installed its own helper. It only ever looks at those fixed paths, and
  /// keeps any bundle that is a link, carries another bundle identifier, is
  /// not owned by root (so the person put it there, not the package), or has
  /// a process running from it. Every refusal is reported, never thrown: the
  /// install it follows must not fail because of it.
  public struct PackageInstalledAppRetirement: Sendable {
    public enum Result: Equatable, Sendable {
      case removed
      case absent
      case keptLink
      case keptNotABundle
      case keptForeignIdentifier(String)
      case keptNotInstalledByPackage
      case keptRunning
      case keptRemovalFailed(String)
    }

    private let applicationsDirectory: URL
    private let privateDirectory: URL
    private let appNames: [String]
    private let bundleIdentifier: String
    private let packageOwner: uid_t
    private let runningExecutablePaths: @Sendable () -> [String]

    /// - Parameter privateDirectory: where a candidate is moved before it is
    ///   checked again and deleted. It is writable only by root, on the same
    ///   volume as `applicationsDirectory`, and deliberately not inside the
    ///   helper's state directory, which self-uninstall deletes: a bundle
    ///   that has to stay aside, say after a crash mid-move, is never swept
    ///   up with it. It is created as needed and removed once empty.
    public init(
      applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
      privateDirectory: URL = URL(
        fileURLWithPath: InstallerProductIdentity.helperWorkingDirectory + ".aside",
        isDirectory: true),
      appNames: [String] = [
        InstallerProductIdentity.appName, InstallerProductIdentity.legacyAppName,
      ],
      bundleIdentifier: String = InstallerProductIdentity.appIdentifier,
      packageOwner: uid_t = 0,
      runningExecutablePaths: @escaping @Sendable () -> [String] =
        PackageInstalledAppRetirement.runningExecutablePaths
    ) {
      self.applicationsDirectory = applicationsDirectory
      self.privateDirectory = privateDirectory
      self.appNames = appNames
      self.bundleIdentifier = bundleIdentifier
      self.packageOwner = packageOwner
      self.runningExecutablePaths = runningExecutablePaths
    }

    /// A one-line account of `run()` for logs.
    public static func summary(_ results: [String: Result]) -> String {
      results.keys.sorted().map { "\($0): \(results[$0].map { "\($0)" } ?? "")" }
        .joined(separator: "; ")
    }

    /// One result per candidate path, keyed by the bundle's file name.
    public func run() -> [String: Result] {
      var results: [String: Result] = [:]
      for name in appNames {
        let bundle = applicationsDirectory.appendingPathComponent(name + ".app", isDirectory: true)
        results[bundle.lastPathComponent] = retire(bundle)
      }
      // Leaves nothing behind unless a bundle had to stay aside.
      rmdir(privateDirectory.path)
      return results
    }

    /// Moves the candidate out of `/Applications` first, then checks and
    /// deletes only what it moved. `/Applications` is writable by the admin
    /// group, so checking in place and then deleting by name would let an
    /// admin process swap another root-owned app in between; the private
    /// directory is out of that process's reach.
    private func retire(_ bundle: URL) -> Result {
      var status = stat()
      guard lstat(bundle.path, &status) == 0 else {
        return .absent
      }
      if status.st_mode & S_IFMT == S_IFLNK {
        return .keptLink
      }
      guard status.st_mode & S_IFMT == S_IFDIR else {
        return .keptNotABundle
      }
      if isRunning(from: bundle) {
        return .keptRunning
      }
      // Only this app, as the package installed it, is ever moved; checked
      // again on what was moved.
      if let verdict = identity(of: bundle, owner: status.st_uid) {
        return verdict
      }
      guard preparePrivateDirectory() else {
        return .keptRemovalFailed("no private directory to move it into")
      }
      let moved = privateDirectory.appendingPathComponent(
        ".retiring-\(UUID().uuidString).app", isDirectory: true)
      // Atomic, never replacing anything, and never following a link.
      guard renamex_np(bundle.path, moved.path, UInt32(RENAME_EXCL)) == 0 else {
        return .keptRemovalFailed("could not move aside: \(String(cString: strerror(errno)))")
      }
      let verdict = check(moved, originallyAt: bundle)
      guard verdict == nil else {
        // Put it back as it was; if something has since taken its name, it
        // stays aside rather than replacing that.
        if renamex_np(moved.path, bundle.path, UInt32(RENAME_EXCL)) != 0 {
          return .keptRemovalFailed("kept aside at \(moved.path): name taken")
        }
        return verdict!
      }
      do {
        try FileManager.default.removeItem(at: moved)
        return .removed
      } catch {
        return .keptRemovalFailed(String(describing: error))
      }
    }

    /// Nil when the moved bundle is exactly what may be removed.
    private func check(_ moved: URL, originallyAt bundle: URL) -> Result? {
      var status = stat()
      guard lstat(moved.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
        return .keptNotABundle
      }
      if let verdict = identity(of: moved, owner: status.st_uid) {
        return verdict
      }
      // A process started from it just before the move now runs from the
      // moved path.
      if isRunning(from: moved) || isRunning(from: bundle) {
        return .keptRunning
      }
      return nil
    }

    /// Nil when the bundle carries this app's identifier and the package's
    /// owner.
    private func identity(of bundle: URL, owner: uid_t) -> Result? {
      let info = bundle.appendingPathComponent("Contents/Info.plist")
      guard let data = try? Data(contentsOf: info),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      else {
        return .keptNotABundle
      }
      let identifier = plist["CFBundleIdentifier"] as? String ?? ""
      guard identifier == bundleIdentifier else {
        return .keptForeignIdentifier(identifier)
      }
      guard owner == packageOwner else {
        return .keptNotInstalledByPackage
      }
      return nil
    }

    /// The private directory exists as a real directory owned like the
    /// package's apps (root) and closed to everyone else.
    private func preparePrivateDirectory() -> Bool {
      if mkdir(privateDirectory.path, 0o700) != 0 && errno != EEXIST {
        return false
      }
      var status = stat()
      return lstat(privateDirectory.path, &status) == 0
        && status.st_mode & S_IFMT == S_IFDIR
        && status.st_uid == packageOwner
        && status.st_mode & 0o077 == 0
    }

    private func isRunning(from bundle: URL) -> Bool {
      let contents = bundle.appendingPathComponent("Contents", isDirectory: true).path + "/"
      return runningExecutablePaths().contains { $0.hasPrefix(contents) }
    }

    /// The executable path of every process this process can see.
    public static func runningExecutablePaths() -> [String] {
      let capacity = proc_listallpids(nil, 0)
      guard capacity > 0 else {
        return []
      }
      var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
      // Returns the number of process IDs written.
      let listed = pids.withUnsafeMutableBytes { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count))
      }
      guard listed > 0 else {
        return []
      }
      let count = min(Int(listed), pids.count)
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      return pids.prefix(count).compactMap { pid in
        guard pid > 0 else { return nil }
        let length = path.withUnsafeMutableBufferPointer { buffer in
          proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        let bytes = path.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
      }
    }
  }
#endif
