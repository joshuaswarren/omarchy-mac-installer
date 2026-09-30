import Foundation

/// Product identity from Packaging/identity.conf, compiled in by the
/// OmarchyInstallerIdentityPlugin.
public enum InstallerProductIdentity {
  public static let appName = InstallerBuildConfiguration.appName
  public static let appIdentifier = InstallerBuildConfiguration.appIdentifier
  public static let helperIdentifier = InstallerBuildConfiguration.helperIdentifier
  public static let helperMachServiceName = helperIdentifier
  public static let helperDaemonPlistName = helperIdentifier + ".plist"
  /// Where the helper's system LaunchDaemon job file lives.
  public static let systemLaunchDaemonDirectory = "/Library/LaunchDaemons"
  /// The absolute path of the helper's system LaunchDaemon plist. Its
  /// presence is the app's synchronous registration signal for the helper.
  public static let systemLaunchDaemonPath =
    systemLaunchDaemonDirectory + "/" + helperDaemonPlistName
  public static let helperWorkingDirectory =
    "/var/db/" + appIdentifier
  public static let clientRequirementEnvironmentVariable =
    "OMARCHY_CLIENT_CODE_SIGNING_REQUIREMENT"
}
