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
  @State private var contentHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0
  @State private var measuredHeightCap: CGFloat?
  private var fixedHeightCap: CGFloat?
  private var preloaded = false
  private var onControlFrame: ((String, CGRect) -> Void)?
  #if DEBUG
    @State private var scenario = RemovalPreviewScenario.success
  #endif

  init(
    isSimulation: Bool, onBusyChanged: @escaping (Bool) -> Void,
    onClose: @escaping () -> Void, onRequiresReview: @escaping () -> Void
  ) {
    self.isSimulation = isSimulation
    self.onBusyChanged = onBusyChanged
    self.onClose = onClose
    self.onRequiresReview = onRequiresReview
    _measuredHeightCap = State(
      initialValue: NSApp?.mainWindow.flatMap(RemovalSheetLayout.heightCap(for:)))
  }

  #if DEBUG
    init(
      previewScenario: RemovalPreviewScenario, heightCap: CGFloat?,
      showsAccountFields: Bool = false,
      onControlFrame: ((String, CGRect) -> Void)? = nil
    ) {
      self.init(
        isSimulation: !showsAccountFields, onBusyChanged: { _ in }, onClose: {},
        onRequiresReview: {})
      let (ticket, message) = previewScenario.previewTicket
      _scenario = State(initialValue: previewScenario)
      _ticket = State(initialValue: ticket)
      _message = State(initialValue: message)
      fixedHeightCap = heightCap
      preloaded = true
      self.onControlFrame = onControlFrame
    }
  #endif

  private var canRemove: Bool {
    ticket != nil && !busy && !submitted && phrase == ticket?.confirmation
      && (isSimulation || (!username.isEmpty && !password.isEmpty))
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(.vertical) {
        scrollingContent
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            contentHeight = $0
          }
      }
      .contentMargins(.bottom, bodyScrolls ? 18 : 0, for: .scrollContent)
      .frame(height: bodyHeight)
      .scrollBounceBehavior(.basedOnSize)
      footer
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          footerHeight = $0
        }
        .overlay(alignment: .top) { if bodyScrolls { Divider() } }
    }
    .frame(width: 520)
    .coordinateSpace(.named(RemovalSheetLayout.coordinateSpace))
    .omarchyTypography()
    .foregroundStyle(OmarchyTheme.text)
    .background(OmarchyTheme.window)
    .background {
      if fixedHeightCap == nil {
        RemovalSheetHeightCapReader { measuredHeightCap = $0 }
      }
    }
    .interactiveDismissDisabled(busy)
    .task { if !preloaded { await prepare() } }
    .onDisappear { password = "" }
    .onChange(of: busy) { _, value in onBusyChanged(value) }
  }

  private var heightCap: CGFloat {
    fixedHeightCap ?? measuredHeightCap ?? RemovalSheetLayout.fallbackHeightCap()
  }

  private var bodyHeight: CGFloat {
    RemovalSheetLayout.bodyHeight(
      content: contentHeight, footer: footerHeight, cap: heightCap)
  }

  private var bodyScrolls: Bool { contentHeight > bodyHeight + 0.5 }

  private var scrollingContent: some View {
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
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding([.horizontal, .top], 26)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let ticket, !submitted {
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
            .reportsFrame("removal-confirmation", to: onControlFrame)
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
          .reportsFrame("remove-omarchy", to: onControlFrame)
        }
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 26)
    .padding(.top, 18)
    .padding(.bottom, 26)
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

enum RemovalSheetLayout {
  static let coordinateSpace = "removal-sheet"
  static let screenMargin: CGFloat = 16
  static let minimumHeightCap: CGFloat = 360

  /// A sheet hangs from just below its parent window's title bar, so it can
  /// only grow down to the bottom of the parent screen's visible frame.
  static func heightCap(
    parentFrame: CGRect, titleBarHeight: CGFloat, visibleFrame: CGRect
  ) -> CGFloat {
    let available =
      min(parentFrame.maxY - titleBarHeight, visibleFrame.maxY) - visibleFrame.minY - screenMargin
    return min(max(available, minimumHeightCap), visibleFrame.height).rounded(.down)
  }

  static func bodyHeight(content: CGFloat, footer: CGFloat, cap: CGFloat) -> CGFloat {
    max(min(content, cap - footer), 0)
  }

  @MainActor static func fallbackHeightCap() -> CGFloat {
    guard let visibleFrame = NSScreen.main?.visibleFrame else { return .greatestFiniteMagnitude }
    return max(visibleFrame.height - screenMargin, minimumHeightCap)
  }

  @MainActor static func heightCap(for parent: NSWindow) -> CGFloat? {
    guard let screen = parent.screen ?? NSScreen.main else { return nil }
    return heightCap(
      parentFrame: parent.frame,
      titleBarHeight: parent.frame.height - parent.contentLayoutRect.height,
      visibleFrame: screen.visibleFrame)
  }
}

extension View {
  fileprivate func reportsFrame(_ id: String, to report: ((String, CGRect) -> Void)?) -> some View {
    onGeometryChange(for: CGRect.self) {
      $0.frame(in: .named(RemovalSheetLayout.coordinateSpace))
    } action: {
      report?(id, $0)
    }
  }
}

private struct RemovalSheetHeightCapReader: NSViewRepresentable {
  let onChange: (CGFloat) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {
    view.onChange = onChange
  }

  final class ReaderView: NSView {
    var onChange: ((CGFloat) -> Void)?
    private var lastCap: CGFloat?

    // Selector observers are removed automatically when the view is freed.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self)
      guard window != nil else { return }
      for name in [
        NSWindow.didMoveNotification, NSWindow.didResizeNotification,
        NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
        NSApplication.didChangeScreenParametersNotification,
      ] {
        center.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
      }
      DispatchQueue.main.async { [weak self] in self?.update() }
    }

    @objc private func changed(_ note: Notification) {
      guard let changed = note.object as? NSWindow else { return update() }
      if changed === window || changed === window?.sheetParent { update() }
    }

    private func update() {
      guard let parent = window?.sheetParent ?? NSApp?.mainWindow, parent !== window,
        let cap = RemovalSheetLayout.heightCap(for: parent), cap != lastCap
      else { return }
      lastCap = cap
      onChange?(cap)
    }
  }
}

#if DEBUG
  enum RemovalPreviewScenario: String, CaseIterable {
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
