#if os(macOS)
  import Foundation
  import OmarchyAppleInstallerTrustCore

  /// How the removal sheet starts. Removal needs the helper even to look for
  /// an installation, so without one the sheet asks for the administrator
  /// account first, sets the helper up with it, and only then scans. The
  /// same password then approves the removal: one prompt for the action.
  public enum RemovalHelperStart: Equatable, Sendable {
    /// A helper is registered: scan right away, as before.
    case scan
    /// No helper, but this build can install one: ask for the account first.
    case credentialsFirst
    /// No helper, and this build cannot install one.
    case unavailable

    public init(helper: HelperDisplay) {
      if helper.status != .missing {
        self = .scan
      } else if helper.canInstall {
        self = .credentialsFirst
      } else {
        self = .unavailable
      }
    }
  }

  extension PlainLanguage {
    public static let removalCredentialsFirst =
      "To look for Omarchy on this Mac, enter your macOS administrator account. It sets up the removal service and approves the removal you’ll review next. macOS will show a notice that \(windowTitle) added a background item."
    public static let removalContinue = "Continue"
    /// Builds that cannot install the helper, when the package has not.
    public static let removalServiceMissing =
      "The removal service isn’t available. Run the downloaded \(installerPackage) again, then try again. No disk changes were made."
    public static let removalServiceNotResponding =
      "The removal service didn’t respond. Close this window and try again. No disk changes were made."

    /// What the removal sheet says when setting up the helper failed.
    public static func removalHelperSetupMessage(for error: any Error) -> String {
      if let submission = error as? EngineXPCSubmissionError,
        submission == .machineOwnerCredentialsRejected
      {
        return
          "The macOS account or password was not accepted. Use a macOS administrator account. No disk changes were made."
      }
      switch error as? InstallerHelperSetupError {
      case .cancelled:
        return
          "The removal service wasn’t set up. Try again, and approve the macOS password prompt if it appears. No disk changes were made."
      case .switchedOff:
        return
          "The removal service is switched off. In System Settings, open General → Login Items & Extensions, switch it on under Allow in the Background, then try again. No disk changes were made."
      case .unavailable:
        return removalServiceMissing
      case .failed, nil:
        return "The removal service couldn’t be set up. Try again. No disk changes were made."
      }
    }
  }
#endif
