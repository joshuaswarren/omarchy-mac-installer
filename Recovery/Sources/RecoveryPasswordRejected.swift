import Foundation

/// The owner's password was refused, so the person can simply enter it again.
/// The authorization helper decides this from the command's raw output; see
/// `aurora_authorization_password_rejected`.
struct RecoveryPasswordRejected: Error, LocalizedError {
  let username: String
  var errorDescription: String? { "The password for \(username) was not accepted." }
}
