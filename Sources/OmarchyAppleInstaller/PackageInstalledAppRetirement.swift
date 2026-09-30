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
    private let appNames: [String]
    private let bundleIdentifier: String
    private let packageOwner: uid_t
    private let runningExecutablePaths: @Sendable () -> [String]

    public init(
      applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
      appNames: [String] = [
        InstallerProductIdentity.appName, InstallerProductIdentity.legacyAppName,
      ],
      bundleIdentifier: String = InstallerProductIdentity.appIdentifier,
      packageOwner: uid_t = 0,
      runningExecutablePaths: @escaping @Sendable () -> [String] =
        PackageInstalledAppRetirement.runningExecutablePaths
    ) {
      self.applicationsDirectory = applicationsDirectory
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
      return results
    }

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
      guard status.st_uid == packageOwner else {
        return .keptNotInstalledByPackage
      }
      let contents = bundle.appendingPathComponent("Contents", isDirectory: true).path + "/"
      if runningExecutablePaths().contains(where: { $0.hasPrefix(contents) }) {
        return .keptRunning
      }
      do {
        try FileManager.default.removeItem(at: bundle)
        return .removed
      } catch {
        return .keptRemovalFailed(String(describing: error))
      }
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
