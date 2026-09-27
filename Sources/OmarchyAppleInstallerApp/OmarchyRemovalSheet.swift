import AppKit
import OmarchyAppleInstallerTrustCore
import OmarchyInstallerUXCore
import SwiftUI

struct OmarchyRemovalSheet: View {
  let isSimulation: Bool
  let onBusyChanged: (Bool) -> Void
  let onClose: () -> Void
  let onRequiresReview: () -> Void

  @State private var ticket: OmarchyRemovalTicket?
  @State private var phrase = ""
  @State private var username = NSUserName()
  @State private var password = ""
  @State private var busy = false
  @State private var submitted = false
  @State private var completed = false
  @State private var message = "Checking for an existing Omarchy installation…"
  @State private var client: AuthenticatedEngineXPCSubmitter?
  #if DEBUG
    @State private var scenario = RemovalPreviewScenario.success
  #endif

  private var canRemove: Bool {
    ticket != nil && !busy && !submitted && phrase == ticket?.confirmation
      && (isSimulation || (!username.isEmpty && !password.isEmpty))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(heading)
        .font(OmarchyTheme.title)
        .foregroundStyle(OmarchyTheme.accent)
      #if DEBUG
        if isSimulation {
          Picker("Removal test", selection: $scenario) {
            ForEach(RemovalPreviewScenario.allCases, id: \.self) { item in
              Text(item.rawValue).tag(item)
            }
          }
          .disabled(busy)
          .onChange(of: scenario) { _, _ in Task { await prepare() } }
          Text("SIMULATION · No disks will be changed")
            .font(OmarchyTheme.detail)
            .foregroundStyle(OmarchyTheme.secondaryText)
        }
      #endif
      Text(message)
        .font(OmarchyTheme.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("removal-message")
      if let ticket, !submitted {
        VStack(alignment: .leading, spacing: 10) {
          if !ticket.deletions.isEmpty {
            planSection("Deleted", items: ticket.deletions)
          }
          summaryRow("Space returned to macOS", value: PlainLanguage.bytes(ticket.reclaimBytes))
          summaryRow("macOS after removal", value: PlainLanguage.bytes(ticket.macOSBytesAfter))
          planSection("Stays as it is", items: ticket.kept)
        }
        .padding(14)
        .background(OmarchyTheme.card, in: RoundedRectangle(cornerRadius: 8))
        ForEach(ticket.notes, id: \.self) { note in
          Text(note)
            .font(OmarchyTheme.body)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          ticket.kind == .freeSpace
            ? "Your macOS files stay as they are. This can’t be undone."
            : "Your macOS files stay as they are. Everything in the deleted partitions is lost. Removal can’t be undone."
        )
        .font(OmarchyTheme.body)
        .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 7) {
          Text("Type this to confirm:")
            .foregroundStyle(OmarchyTheme.secondaryText)
          Text(ticket.confirmation)
            .font(OmarchyTheme.heading)
            .textSelection(.enabled)
          TextField("Confirmation phrase", text: $phrase)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .accessibilityIdentifier("removal-confirmation")
        }
        .font(OmarchyTheme.body)
        if !isSimulation {
          VStack(alignment: .leading, spacing: 7) {
            Text("macOS administrator account").foregroundStyle(OmarchyTheme.secondaryText)
            TextField("Account name", text: $username)
              .textFieldStyle(.roundedBorder)
              .textContentType(.username)
              .autocorrectionDisabled()
            SecureField("macOS password", text: $password)
              .textFieldStyle(.roundedBorder)
              .textContentType(.password)
              .privacySensitive()
          }
          .font(OmarchyTheme.body)
        }
      }
      if busy {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(submitted ? "Keep your Mac on until removal finishes." : "Reading the disk layout…")
            .font(OmarchyTheme.detail)
        }
        .foregroundStyle(OmarchyTheme.secondaryText)
      }
      HStack(spacing: 12) {
        Spacer()
        Button(submitted || ticket == nil ? "Close" : "Cancel") {
          password = ""
          onClose()
        }
        .omarchySecondaryButton()
        .keyboardShortcut(.cancelAction)
        .focusEffectDisabled()
        .disabled(busy)
        if let ticket, !submitted {
          Button(ticket.kind == .freeSpace ? "Return Space" : "Remove Omarchy", role: .destructive)
          { Task { await remove() } }
          .omarchyDangerButton()
          .disabled(!canRemove)
          .accessibilityIdentifier("remove-omarchy")
        }
      }
      .padding(.top, 4)
    }
    .padding(26)
    .frame(width: 520)
    .omarchyTypography()
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .interactiveDismissDisabled(busy)
    .task { await prepare() }
    .onDisappear { password = "" }
    .onChange(of: busy) { _, value in onBusyChanged(value) }
  }

  private var heading: String {
    if ticket?.kind == .freeSpace { return completed ? "Space returned" : "Return free space" }
    return completed ? "Omarchy removed" : "Remove Omarchy"
  }

  private func planSection(_ title: String, items: [OmarchyRemovalItem]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).foregroundStyle(OmarchyTheme.secondaryText)
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
            Text(item.detail)
              .font(OmarchyTheme.detail)
              .foregroundStyle(OmarchyTheme.secondaryText)
          }
          Spacer()
          Text(PlainLanguage.bytes(item.bytes)).fontWeight(.medium)
        }
      }
    }
    .font(OmarchyTheme.body)
  }

  private func summaryRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(OmarchyTheme.secondaryText)
      Spacer()
      Text(value).fontWeight(.medium)
    }.font(OmarchyTheme.body)
  }

  @MainActor private func prepare() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    ticket = nil
    phrase = ""
    password = ""
    submitted = false
    completed = false
    message = "Checking for an existing Omarchy installation…"
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .milliseconds(350))
        if scenario == .none || scenario == .ambiguous || scenario == .helperUnavailable {
          message = scenario.message
        } else {
          (ticket, message) = scenario.previewTicket
        }
        return
      }
    #endif
    do {
      let configuration = try InstallerReleaseConfigurationLocator().loadFromMainBundle()
      let submitter = try AuthenticatedEngineXPCSubmitter(
        machServiceName: configuration.helperMachServiceName,
        helperCodeSigningRequirement: configuration.helperCodeSigningRequirement)
      client = submitter
      let reply = try await submitter.removal()
      ticket = reply.ticket
      message = reply.message
    } catch {
      message =
        "The removal service isn’t available. Run the downloaded \(PlainLanguage.installerPackage) again, then try again. No disk changes were made."
    }
  }

  @MainActor private func remove() async {
    guard canRemove, let ticket else { return }
    let authorization: MachineOwnerAuthorization?
    do {
      authorization =
        isSimulation
        ? nil : try MachineOwnerAuthorization(username: username, password: Data(password.utf8))
    } catch {
      message = "Enter a valid macOS administrator account and password."
      return
    }
    password = ""
    busy = true
    submitted = true
    message = "Removing Omarchy, then returning its space to macOS…"
    defer { busy = false }
    #if DEBUG
      if isSimulation {
        try? await Task.sleep(for: .seconds(2))
        if scenario == .disconnected {
          connectionLost()
          return
        }
        completed = [.success, .asahi, .freeSpace].contains(scenario)
        if [.interrupted, .reclaimFailed, .disconnected].contains(scenario) { onRequiresReview() }
        message = scenario.message
        return
      }
    #endif
    do {
      guard let client else { throw EngineXPCSubmissionError.connectionFailed }
      let reply = try await client.removal(
        ticket: ticket, confirmation: phrase, authorization: authorization)
      completed = reply.completed
      if reply.requiresReview { onRequiresReview() }
      message = reply.message
    } catch {
      connectionLost()
    }
  }

  private func connectionLost() {
    onRequiresReview()
    message =
      "The connection to the removal service was lost. Removal may still be running. Don’t restart removal or turn off this Mac. Check the removal record before continuing."
  }
}

#if DEBUG
  private enum RemovalPreviewScenario: String, CaseIterable {
    case success = "Complete removal"
    case asahi = "Older omarchy-mac installation"
    case freeSpace = "Free space only"
    case none = "No installation"
    case ambiguous = "Unfamiliar or partial layout"
    case helperUnavailable = "Helper unavailable"
    case credentials = "Incorrect password"
    case changed = "Disk changed since confirmation"
    case interrupted = "Deletion interrupted"
    case reclaimFailed = "macOS resize failed"
    case disconnected = "Connection lost"

    var previewTicket: (OmarchyRemovalTicket, String) {
      let kept = [
        OmarchyRemovalItem(
          title: "macOS “Macintosh HD”", detail: "disk0s2 · grows to 494.4 GB",
          bytes: 461_600_000_000),
        OmarchyRemovalItem(title: "Apple system container", detail: "disk0s1", bytes: 524_288_000),
        OmarchyRemovalItem(title: "Apple Recovery", detail: "disk0s6", bytes: 5_368_664_064),
      ]
      switch self {
      case .freeSpace:
        return (
          OmarchyRemovalTicket(
            id: UUID(), kind: .freeSpace, reclaimBytes: 32_800_505_856,
            macOSBytesAfter: 494_400_505_856, kept: kept,
            notes: [
              "macOS takes all the unallocated space directly after it, whatever put it there."
            ]),
          "No installation was found, but 32.8 GB directly after macOS is unallocated. macOS can take it back. Nothing will be deleted."
        )
      case .asahi:
        return (
          OmarchyRemovalTicket(
            id: UUID(), reclaimBytes: 32_800_505_856, macOSBytesAfter: 494_400_505_856,
            deletions: [
              OmarchyRemovalItem(
                title: "Startup container “Arch Linux ARM”", detail: "disk0s3 · APFS",
                bytes: 2_499_805_184),
              OmarchyRemovalItem(
                title: "EFI partition “EFI - ARCH”", detail: "disk0s4", bytes: 524_288_000),
              OmarchyRemovalItem(
                title: "Linux partition", detail: "disk0s5", bytes: 29_776_412_672),
            ], kept: kept),
          "Found “Arch Linux ARM”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
        )
      default:
        return (
          OmarchyRemovalTicket(
            id: UUID(), reclaimBytes: 275_000_000_000, macOSBytesAfter: 995_000_000_000,
            deletions: [
              OmarchyRemovalItem(
                title: "Startup container “Omarchy”", detail: "disk0s3 · APFS",
                bytes: 2_499_805_184),
              OmarchyRemovalItem(
                title: "EFI partition “EFI - OMARC”", detail: "disk0s4", bytes: 524_288_000),
              OmarchyRemovalItem(title: "Linux partition", detail: "disk0s5", bytes: 2_147_483_648),
              OmarchyRemovalItem(
                title: "Linux partition", detail: "disk0s6", bytes: 269_828_710_400),
            ], kept: kept),
          "Found “Omarchy”. Removal permanently deletes it and everything stored in it, then returns its space to macOS."
        )
      }
    }

    var message: String {
      switch self {
      case .success:
        "“Omarchy” and its data have been removed. The freed space is now part of macOS."
      case .asahi:
        "“Arch Linux ARM” and its data have been removed. The freed space is now part of macOS."
      case .freeSpace: "The free space is now part of macOS."
      case .none:
        "No Omarchy installation, or other installation made with the Asahi installer, was found, and there’s no unallocated space after macOS. Nothing was changed."
      case .ambiguous:
        "Found disk0s4 (EFI partition, “EFI - ARCH”, 524.3 MB); disk0s5 (Linux partition, 29.8 GB) without the startup container every installation made with the Asahi installer has. This looks like a partly removed installation, which needs a manual review. Nothing was changed."
      case .helperUnavailable:
        "The removal service isn’t available. Run the downloaded \(PlainLanguage.installerPackage) again, then try again. No disk changes were made."
      case .credentials:
        "The macOS account or password was not accepted. No disk changes were made."
      case .changed:
        "The disk layout changed since you reviewed it. No disk changes were made. Close this window and review removal again."
      case .interrupted:
        "Removal stopped, and some Omarchy data may already be deleted. Don’t start removal again; the removal record was kept for recovery."
      case .reclaimFailed:
        "Omarchy was removed, but the installer couldn’t confirm its space went back to macOS. The space may still be unallocated. Don’t start removal again; the removal record was kept for recovery."
      case .disconnected:
        "The connection to the removal service was lost. Removal may still be running. Don’t restart removal or turn off this Mac. Check the removal record before continuing."
      }
    }
  }
#endif
