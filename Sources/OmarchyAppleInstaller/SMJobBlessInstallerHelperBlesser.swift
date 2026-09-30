#if os(macOS)
  import Foundation
  import Security
  import ServiceManagement

  /// Installs the helper bundled in the app with `SMJobBless`, which copies it
  /// into `/Library/PrivilegedHelperTools`, owned by root, and registers its
  /// launchd job. The silent route pre-authorizes with the credentials the
  /// person just typed and never allows interaction; the dialog route lets
  /// macOS show its own administrator dialog. Checked on macOS 15.7.7 and
  /// 26.6.2.
  public struct SMJobBlessInstallerHelperBlesser: InstallerHelperBlessing {
    private static let blessRight = "com.apple.ServiceManagement.blesshelper"

    private let label: String

    public init(label: String = InstallerProductIdentity.helperIdentifier) {
      self.label = label
    }

    /// Whether the app bundle declares the helper for `SMJobBless`. Builds
    /// without a real signing identity leave the declaration out, and then
    /// cannot install the helper themselves.
    public static func isDeclared(
      in bundle: Bundle = .main,
      label: String = InstallerProductIdentity.helperIdentifier
    ) -> Bool {
      let executables = bundle.infoDictionary?["SMPrivilegedExecutables"] as? [String: String]
      return executables?[label]?.isEmpty == false
    }

    public func blessSilently(
      with authorization: MachineOwnerAuthorization
    ) async -> InstallerHelperBlessResult {
      let label = label
      return await Task.detached {
        Self.bless(label: label, credentials: authorization, allowingDialog: false)
      }.value
    }

    public func blessWithDialog() async -> InstallerHelperBlessResult {
      let label = label
      return await Task.detached {
        Self.bless(label: label, credentials: nil, allowingDialog: true)
      }.value
    }

    private static func bless(
      label: String,
      credentials: MachineOwnerAuthorization?,
      allowingDialog: Bool
    ) -> InstallerHelperBlessResult {
      var reference: AuthorizationRef?
      guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess,
        let reference
      else {
        return .failed("AuthorizationCreate failed")
      }
      defer { AuthorizationFree(reference, []) }

      let status = copyBlessRight(
        reference, credentials: credentials, allowingDialog: allowingDialog)
      switch status {
      case errAuthorizationSuccess:
        break
      case errAuthorizationDenied, errAuthorizationInteractionNotAllowed:
        return .refused
      case errAuthorizationCanceled:
        return .cancelled
      default:
        return .failed("AuthorizationCopyRights returned \(status)")
      }

      var error: Unmanaged<CFError>?
      guard SMJobBless(kSMDomainSystemLaunchd, label as CFString, reference, &error) else {
        let message = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
        return .failed("SMJobBless failed: \(message)")
      }
      return .blessed
    }

    /// Requests the bless right. With credentials, they go in the
    /// authorization environment and are wiped from memory before returning.
    private static func copyBlessRight(
      _ reference: AuthorizationRef,
      credentials: MachineOwnerAuthorization?,
      allowingDialog: Bool
    ) -> OSStatus {
      var flags: AuthorizationFlags = [.extendRights, .preAuthorize]
      if allowingDialog {
        flags.insert(.interactionAllowed)
      }
      return blessRight.withCString { rightName in
        var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &right) { rightPointer in
          var rights = AuthorizationRights(count: 1, items: rightPointer)
          guard let credentials else {
            return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
          }
          return withEnvironment(credentials) { environment in
            AuthorizationCopyRights(reference, &rights, environment, flags, nil)
          }
        }
      }
    }

    private static func withEnvironment(
      _ credentials: MachineOwnerAuthorization,
      _ body: (UnsafePointer<AuthorizationEnvironment>) -> OSStatus
    ) -> OSStatus {
      let username = Array(credentials.username.utf8CString)
      var password = [CChar](repeating: 0, count: credentials.password.count + 1)
      credentials.password.withUnsafeBytes { bytes in
        for (index, byte) in bytes.enumerated() {
          password[index] = CChar(bitPattern: byte)
        }
      }
      defer {
        for index in password.indices {
          password[index] = 0
        }
      }
      return username.withUnsafeBufferPointer { usernameBytes in
        password.withUnsafeMutableBufferPointer { passwordBytes in
          kAuthorizationEnvironmentUsername.withCString { usernameKey in
            kAuthorizationEnvironmentPassword.withCString { passwordKey in
              var items = [
                AuthorizationItem(
                  name: usernameKey,
                  valueLength: usernameBytes.count - 1,
                  value: UnsafeMutableRawPointer(mutating: usernameBytes.baseAddress),
                  flags: 0),
                AuthorizationItem(
                  name: passwordKey,
                  valueLength: passwordBytes.count - 1,
                  value: UnsafeMutableRawPointer(passwordBytes.baseAddress),
                  flags: 0),
              ]
              return items.withUnsafeMutableBufferPointer { itemBytes in
                var environment = AuthorizationEnvironment(
                  count: UInt32(itemBytes.count), items: itemBytes.baseAddress)
                return body(&environment)
              }
            }
          }
        }
      }
    }
  }
#endif
