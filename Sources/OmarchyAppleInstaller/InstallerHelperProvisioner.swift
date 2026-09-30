#if os(macOS)
  import Foundation
  import OSLog

  /// Where the privileged helper stands, as the app sees it.
  public enum InstallerHelperStatus: Equatable, Sendable {
    /// No helper is registered with launchd.
    case missing
    /// The helper answers and is the build this app carries.
    case current
    /// The helper answers but reports a different build, or none at all, as
    /// helpers installed by the installer package do.
    case outdated
    /// The helper is registered but does not answer, for example because the
    /// person switched it off in Login Items.
    case disabled
  }

  /// What `InstallerHelperProvisioner.ensureCurrent` did.
  public enum InstallerHelperProvisioningOutcome: Equatable, Sendable {
    /// The helper was already current; nothing was installed.
    case alreadyCurrent
    /// Installed with the typed credentials and no system dialog.
    case installedSilently
    /// macOS refused the typed credentials, so its own administrator dialog
    /// was shown and the person approved it there.
    case installedWithDialog
    /// The typed name or password was not accepted locally. Nothing was
    /// attempted.
    case credentialsRejected
    /// The person cancelled macOS's administrator dialog, or macOS refused it.
    case cancelled
    /// The helper is switched off and was left that way.
    case disabled
    /// This build cannot install the helper itself.
    case unavailable
    /// Installation reported success but the helper does not answer, or the
    /// installation failed outright. The message is for diagnostics only.
    case failed(String)
  }

  /// Observes the installed helper. The shipping probe checks launchd's job
  /// file and asks the helper over XPC; tests supply a fake.
  public protocol InstallerHelperProbing: Sendable {
    /// Cheap and synchronous, safe on the main actor: whether launchd has the
    /// helper's job file.
    var isRegistered: Bool { get }
    /// Whether the helper answers a ping in time.
    func answers() async -> Bool
    /// The build the running helper reports, or nil when it reports none.
    func reportedVersion() async -> String?
  }

  public enum InstallerHelperBlessResult: Equatable, Sendable {
    case blessed
    /// macOS refused the authorization; nothing was installed.
    case refused
    /// The person cancelled macOS's administrator dialog.
    case cancelled
    /// This build cannot install the helper.
    case unavailable
    case failed(String)
  }

  /// Installs the helper bundled in the app, replacing any installed copy.
  public protocol InstallerHelperBlessing: Sendable {
    /// Uses the typed credentials and never shows a system dialog.
    func blessSilently(
      with authorization: MachineOwnerAuthorization
    ) async -> InstallerHelperBlessResult
    /// Lets macOS show its own administrator dialog.
    func blessWithDialog() async -> InstallerHelperBlessResult
  }

  /// Follow-up work once the app has installed its own helper, such as
  /// removing the app the installer package left in /Applications. It runs
  /// in the background and can never hold up or fail the setup.
  public protocol InstallerHelperHousekeeping: Sendable {
    func afterInstall() async
  }

  public struct NoInstallerHelperHousekeeping: InstallerHelperHousekeeping {
    public init() {}
    public func afterInstall() async {}
  }

  /// The blesser for builds that still rely on the installer package to put
  /// the helper in place.
  public struct UnavailableInstallerHelperBlesser: InstallerHelperBlessing {
    public init() {}

    public func blessSilently(
      with authorization: MachineOwnerAuthorization
    ) async -> InstallerHelperBlessResult {
      .unavailable
    }

    public func blessWithDialog() async -> InstallerHelperBlessResult {
      .unavailable
    }
  }

  /// Decides whether the privileged helper needs installing and installs it
  /// with the credentials the person typed for the action at hand. It keeps
  /// no credential: each call uses the one it is given and forgets it.
  public struct InstallerHelperProvisioner: Sendable {
    private let probe: any InstallerHelperProbing
    private let blesser: any InstallerHelperBlessing
    private let credentialValidator: any MachineOwnerCredentialValidating
    private let bundledHelperVersion: String?
    private let housekeeping: any InstallerHelperHousekeeping

    /// - Parameter bundledHelperVersion: the build of the helper this app
    ///   carries. When nil the app cannot tell builds apart, and any helper
    ///   that answers counts as current.
    /// - Parameter housekeeping: started, not awaited, after each install.
    public init(
      probe: any InstallerHelperProbing,
      blesser: any InstallerHelperBlessing,
      credentialValidator: any MachineOwnerCredentialValidating,
      bundledHelperVersion: String?,
      housekeeping: any InstallerHelperHousekeeping = NoInstallerHelperHousekeeping()
    ) {
      self.probe = probe
      self.blesser = blesser
      self.credentialValidator = credentialValidator
      self.bundledHelperVersion = bundledHelperVersion
      self.housekeeping = housekeeping
    }

    /// The build of the helper an app bundle carries: the `CFBundleVersion`
    /// of the Info.plist linked into the helper binary. Nil when the bundle
    /// has no helper there or the helper carries no version.
    public static func bundledHelperVersion(
      in bundle: Bundle = .main,
      label: String = InstallerProductIdentity.helperIdentifier
    ) -> String? {
      let helper = bundle.bundleURL
        .appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        .appendingPathComponent(label, isDirectory: false)
      guard FileManager.default.isExecutableFile(atPath: helper.path),
        let info = CFBundleCopyInfoDictionaryForURL(helper as CFURL) as? [String: Any],
        let version = info["CFBundleVersion"] as? String, !version.isEmpty
      else {
        return nil
      }
      return version
    }

    /// The synchronous status the screens show: missing, or current as far as
    /// the job file tells. `probeStatus()` refines current into outdated or
    /// disabled.
    public var registrationStatus: InstallerHelperStatus {
      probe.isRegistered ? .current : .missing
    }

    /// Asks the helper, so it may take a few seconds when the helper is slow
    /// or switched off.
    public func probeStatus() async -> InstallerHelperStatus {
      guard probe.isRegistered else {
        return .missing
      }
      guard await probe.answers() else {
        return .disabled
      }
      guard let bundledHelperVersion else {
        return .current
      }
      return await probe.reportedVersion() == bundledHelperVersion ? .current : .outdated
    }

    /// Makes the helper current for the action the person just authorized.
    /// The typed credentials are checked locally first, so a typo never leads
    /// to a system dialog; macOS's dialog appears only when the credentials
    /// were right and macOS still refused to use them.
    public func ensureCurrent(
      _ authorization: MachineOwnerAuthorization
    ) async -> InstallerHelperProvisioningOutcome {
      do {
        try credentialValidator.validate(authorization)
      } catch {
        return .credentialsRejected
      }
      switch await probeStatus() {
      case .current:
        return .alreadyCurrent
      case .disabled:
        return .disabled
      case .missing, .outdated:
        break
      }
      switch await blesser.blessSilently(with: authorization) {
      case .blessed:
        return await confirmCurrent(.installedSilently)
      case .refused:
        break
      case .cancelled:
        return .cancelled
      case .unavailable:
        return .unavailable
      case .failed(let message):
        return .failed(message)
      }
      switch await blesser.blessWithDialog() {
      case .blessed:
        return await confirmCurrent(.installedWithDialog)
      case .refused, .cancelled:
        return .cancelled
      case .unavailable:
        return .unavailable
      case .failed(let message):
        return .failed(message)
      }
    }

    /// After installing, the bundled build must be the one answering: a
    /// helper that is silent, or still reports another build, is a failure.
    private func confirmCurrent(
      _ outcome: InstallerHelperProvisioningOutcome
    ) async -> InstallerHelperProvisioningOutcome {
      switch await probeStatus() {
      case .current:
        let housekeeping = housekeeping
        Task.detached { await housekeeping.afterInstall() }
        return outcome
      case .outdated:
        return .failed("The helper was installed but an older build still answers.")
      case .missing, .disabled:
        return .failed("The helper was installed but does not answer.")
      }
    }
  }

  /// The shipping housekeeping: asks the freshly installed helper to remove
  /// the app the installer package left behind, and logs what it did.
  public struct SystemInstallerHelperHousekeeping: InstallerHelperHousekeeping {
    private static let logger = Logger(subsystem: "com.omarchy.installer", category: "helper")
    private let submitter: @Sendable () throws -> AuthenticatedEngineXPCSubmitter

    public init(
      submitter: @escaping @Sendable () throws -> AuthenticatedEngineXPCSubmitter
    ) {
      self.submitter = submitter
    }

    public func afterInstall() async {
      guard let submitter = try? submitter() else {
        return
      }
      let summary = await submitter.retirePackageInstalledApps() ?? "no answer"
      Self.logger.info("package-installed app retirement: \(summary, privacy: .public)")
    }
  }

  /// The shipping probe: launchd's job file for the synchronous check, and
  /// the helper's own XPC service for the rest.
  public struct SystemInstallerHelperProbe: InstallerHelperProbing {
    private let submitter: @Sendable () throws -> AuthenticatedEngineXPCSubmitter

    /// - Parameter submitter: builds a connection to the helper from the
    ///   release configuration; a failure counts as a helper that does not
    ///   answer.
    public init(
      submitter: @escaping @Sendable () throws -> AuthenticatedEngineXPCSubmitter
    ) {
      self.submitter = submitter
    }

    public var isRegistered: Bool {
      FileManager.default.fileExists(
        atPath: InstallerProductIdentity.systemLaunchDaemonPath
      )
    }

    public func answers() async -> Bool {
      do {
        try await submitter().ping()
        return true
      } catch {
        return false
      }
    }

    public func reportedVersion() async -> String? {
      guard let submitter = try? submitter() else {
        return nil
      }
      return await submitter.helperVersion()
    }
  }
#endif
