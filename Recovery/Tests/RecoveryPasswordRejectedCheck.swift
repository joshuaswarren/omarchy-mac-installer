import Foundation

@main struct Check {
  static func main() {
    precondition(
      RecoveryPasswordRejected(username: "owner").localizedDescription
        == "The password for owner was not accepted.")
    print("PASS password rejection message")
  }
}
