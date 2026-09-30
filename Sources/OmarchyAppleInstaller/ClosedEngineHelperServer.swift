#if os(macOS)
  import Foundation
  import Darwin

  public enum EngineHandoffOperation: String, Equatable, Sendable {
    case install
    case retryRecoveryAuthorization = "retry-recovery-authorization"
  }

  public protocol ImportedEngineHandoffExecuting: Sendable {
    func execute(
      _ package: ImportedEngineHandoffPackage,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation
    ) async throws -> Data
  }

  public enum ClosedEngineHelperError: Error, Equatable, Sendable {
    case busy
    case invalidOperation
    case invalidMachineOwnerCredentials
    case invalidClientRequirement
    case unsupportedDevice(String)
    case transcriptDeviceMismatch
    case transcriptIncomplete
    case transcriptPlanMismatch
    case installConfPlanIncomplete
    case installConfTargetMismatch
    case installConfReplay
  }

  public actor ClosedEngineHelperServer {
    private static let explicitlyUnsupportedDevices = ["apple,j614s"]

    private let workingDirectory: URL
    private let credentialValidator: any MachineOwnerCredentialValidating
    private let executor: any ImportedEngineHandoffExecuting
    private let importer: EngineHandoffPackageImporter
    private let removalDisks: any RemovalDiskOperating
    private let removalAdminValidator: @Sendable (MachineOwnerAuthorization) throws -> Void
    private let espDisks: any InstallConfESPDiskOperating
    private let selfUninstaller: any HelperSelfUninstalling
    private var isExecuting = false
    private var completedInstallPlan: CompletedEngineInstallPlan?
    private var installConfConsumed = false
    private var removalPlan:
      (ticket: OmarchyRemovalTicket, plan: OmarchyRemovalPlan, expires: Date)?

    public init(
      workingDirectory: URL,
      executor: any ImportedEngineHandoffExecuting,
      credentialValidator: any MachineOwnerCredentialValidating =
        OpenDirectoryMachineOwnerCredentialValidator(),
      selfUninstaller: any HelperSelfUninstalling = NoHelperSelfUninstall()
    ) {
      self.workingDirectory = workingDirectory
      self.executor = executor
      self.credentialValidator = credentialValidator
      importer = EngineHandoffPackageImporter()
      removalDisks = MacRemovalDiskOperator()
      removalAdminValidator = requireRemovalAdministrator
      espDisks = DiskutilInstallConfESPOperator()
      self.selfUninstaller = selfUninstaller
    }

    init(
      workingDirectory: URL, executor: any ImportedEngineHandoffExecuting,
      credentialValidator: any MachineOwnerCredentialValidating,
      removalDisks: any RemovalDiskOperating,
      removalAdminValidator: @escaping @Sendable (MachineOwnerAuthorization) throws -> Void,
      espDisks: any InstallConfESPDiskOperating = DiskutilInstallConfESPOperator(),
      selfUninstaller: any HelperSelfUninstalling = NoHelperSelfUninstall()
    ) {
      self.workingDirectory = workingDirectory
      self.executor = executor
      self.credentialValidator = credentialValidator
      importer = EngineHandoffPackageImporter()
      self.removalDisks = removalDisks
      self.removalAdminValidator = removalAdminValidator
      self.espDisks = espDisks
      self.selfUninstaller = selfUninstaller
    }

    public func removal(
      ticketID: UUID?, confirmation: String, authorization: MachineOwnerAuthorization?
    ) async throws -> OmarchyRemovalReply {
      guard !isExecuting else { throw ClosedEngineHelperError.busy }
      try requireNoInterruptedRemoval()
      isExecuting = true
      defer { isExecuting = false }
      let disks = removalDisks
      let validateAdministrator = removalAdminValidator
      if ticketID == nil {
        removalPlan = nil
        let plan = try await Task.detached {
          try OmarchyRemovalPlan(disks: disks)
        }.value
        let ticket = plan.ticket(id: UUID())
        removalPlan = (ticket, plan, Date().addingTimeInterval(300))
        return OmarchyRemovalReply(ticket: ticket, message: plan.summary)
      }
      guard let authorization, let approved = removalPlan,
        approved.ticket.id == ticketID, approved.expires > Date(),
        confirmation == approved.ticket.confirmation
      else {
        throw RemovalFailure(
          message:
            "The confirmation is incorrect or has expired. Close this window and review removal again. Nothing was changed."
        )
      }
      // One use only, including failures. A fresh review must obtain a new plan.
      removalPlan = nil
      let validator = credentialValidator
      let selfUninstaller = self.selfUninstaller
      let workingDirectory = self.workingDirectory
      let journalURL = workingDirectory.appendingPathComponent(
        "removal-\(approved.ticket.id.uuidString).json")
      return await Task.detached {
        var phase = "checking"
        do {
          do { try validator.validate(authorization) } catch {
            throw RemovalFailure(message: "The macOS account or password was not accepted.")
          }
          try validateAdministrator(authorization)
          let executor = OmarchyRemovalExecutor(disks: disks)
          try executor.execute(approved.plan, authorization: authorization) { next in
            // The private journal is durable before each mutation, without credentials.
            let journal = RemovalJournal(plan: approved.plan, phase: next)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            let file = try FileHandle(forWritingTo: journalURL)
            try file.synchronize()
            try file.close()
            let directory = open(workingDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else {
              throw RemovalFailure(message: "The removal record couldn’t be saved.")
            }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else {
              throw RemovalFailure(message: "The removal record couldn’t be saved.")
            }
            phase = next
          }
          let name = approved.plan.installation?.name
          var message =
            name.map {
              "“\($0)” and its data have been removed. The freed space is now part of macOS."
            } ?? "The free space is now part of macOS."
          do {
            try retireExecutionJournals(in: workingDirectory, removal: approved.ticket.id)
          } catch {
            message +=
              " The installer couldn’t clear its record of the earlier installation, so installing again at the same size may not work."
          }
          // Nothing of Omarchy is left, so the helper goes too, once this
          // reply has reached the app.
          selfUninstaller.uninstallAfterRemoval()
          return OmarchyRemovalReply(completed: true, message: message)
        } catch {
          let detail = (error as? RemovalFailure)?.message ?? "macOS could not complete removal."
          let message: String
          if phase == "checking" {
            message =
              (error as? RemovalFailure)?.complete == true
              ? detail : "\(detail) No disk changes were made."
          } else if approved.plan.kind == .freeSpace {
            message =
              "macOS couldn’t confirm it took the free space. The space may still be unallocated. \(detail) Don’t start again; the removal record was kept for recovery."
          } else if phase == "returning-space-to-macos" || phase == "complete" {
            message =
              "“\(approved.plan.installation?.name ?? "Omarchy")” was removed, but the installer couldn’t confirm its space went back to macOS. The space may still be unallocated. \(detail) Don’t start removal again; the removal record was kept for recovery."
          } else {
            message =
              "Removal stopped, and some data in “\(approved.plan.installation?.name ?? "Omarchy")” may already be deleted. \(detail) Don’t start removal again; the removal record was kept for recovery."
          }
          return OmarchyRemovalReply(requiresReview: phase != "checking", message: message)
        }
      }.value
    }

    private func requireNoInterruptedRemoval() throws {
      let entries = try FileManager.default.contentsOfDirectory(
        at: workingDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      for entry in entries
      where entry.lastPathComponent.hasPrefix("removal-") && entry.pathExtension == "json" {
        let properties = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
          let journal = try? JSONDecoder().decode(
            RemovalJournalPhase.self, from: Data(contentsOf: entry)),
          journal.phase == "complete"
        else {
          throw RemovalFailure(
            message:
              "An earlier removal didn’t finish. Check the saved removal record and disk layout before changing any disks."
          )
        }
      }
    }

    /// `progress` is optional and advisory: when a connected app exports the
    /// journal callback, the helper tails the run's journal and forwards whole
    /// lines. Passing nil reproduces the previous behavior exactly.
    public func submit(
      packageDirectory: FileHandle,
      authorization: MachineOwnerAuthorization,
      operation: EngineHandoffOperation = .install,
      progress: (any EngineJournalProgressSink)? = nil
    ) async throws -> Data {
      guard !isExecuting else {
        throw ClosedEngineHelperError.busy
      }
      try requireNoInterruptedRemoval()
      isExecuting = true
      defer { isExecuting = false }

      do {
        try InstallerPerformance.measure("credential_validation") {
          try credentialValidator.validate(authorization)
        }
      } catch {
        throw ClosedEngineHelperError.invalidMachineOwnerCredentials
      }

      let package = try InstallerPerformance.measure("helper_import") {
        try importer.prepare(from: packageDirectory, in: workingDirectory)
      }
      defer { try? FileManager.default.removeItem(at: package.packageURL) }

      guard
        !Self.explicitlyUnsupportedDevices.contains(
          package.deviceIdentifier
        )
      else {
        throw ClosedEngineHelperError.unsupportedDevice(
          package.deviceIdentifier
        )
      }

      var tailer: EngineJournalTailer?
      if let progress,
        let journalURL = EngineJournalLocator.journalURL(
          workingDirectory: workingDirectory,
          bindingDigest: package.bindingDigest
        )
      {
        let started = EngineJournalTailer(
          journalURL: journalURL,
          expectedOwner: geteuid(),
          sink: progress
        )
        await started.start()
        tailer = started
      }

      let result: Data
      do {
        result = try await executor.execute(
          package,
          authorization: authorization,
          operation: operation
        )
      } catch {
        await tailer?.stop()
        if case .engineFailed(let report) = error as? PinnedAsahiEngineExecutionError {
          // The redacted stderr tail stays here, root-only; only the notice
          // travels back to the app.
          EngineFailureDiagnosticsStore.write(
            report,
            operation: operation.rawValue,
            in: workingDirectory
          )
        }
        throw error
      }
      await tailer?.stop()

      let transcript = try AppleInstallerTrustCore()
        .validateEngineTranscript(result)
      guard transcript.support == .supported else {
        throw ClosedEngineHelperError.unsupportedDevice(
          package.deviceIdentifier
        )
      }
      guard transcript.deviceIdentifier == package.deviceIdentifier,
        transcript.plan?.deviceIdentifier == package.deviceIdentifier
      else {
        throw ClosedEngineHelperError.transcriptDeviceMismatch
      }
      guard transcript.plan?.planDigest == package.planDigest else {
        throw ClosedEngineHelperError.transcriptPlanMismatch
      }
      guard transcript.completion != nil else {
        throw ClosedEngineHelperError.transcriptIncomplete
      }
      if let plan = transcript.plan {
        let completed = CompletedEngineInstallPlan(
          storeIdentifier: plan.storeIdentifier,
          offsetBytes: plan.offsetBytes,
          lengthBytes: plan.lengthBytes
        )
        if completedInstallPlan != completed {
          installConfConsumed = false
        }
        completedInstallPlan = completed
      }
      return result
    }

    public func writeInstallConf(
      document: Data,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      authorization: MachineOwnerAuthorization
    ) async throws {
      guard !isExecuting else { throw ClosedEngineHelperError.busy }
      do {
        try credentialValidator.validate(authorization)
      } catch {
        throw ClosedEngineHelperError.invalidMachineOwnerCredentials
      }
      guard let completed = completedInstallPlan else {
        throw ClosedEngineHelperError.installConfPlanIncomplete
      }
      guard !installConfConsumed else {
        throw ClosedEngineHelperError.installConfReplay
      }
      guard completed.storeIdentifier == storeIdentifier,
        completed.offsetBytes == offsetBytes,
        completed.lengthBytes == lengthBytes
      else {
        throw ClosedEngineHelperError.installConfTargetMismatch
      }
      isExecuting = true
      defer { isExecuting = false }
      let conf = try InstallConf.parse(document)
      let disks = espDisks
      let workingDirectory = self.workingDirectory
      let store = completed.storeIdentifier
      let offset = completed.offsetBytes
      let length = completed.lengthBytes
      do {
        try await Task.detached {
          try InstallConfESPMountWriter(
            disks: disks,
            workingDirectory: workingDirectory
          ).write(
            conf,
            storeIdentifier: store,
            offsetBytes: offset,
            lengthBytes: length
          )
        }.value
        installConfConsumed = true
      } catch let error as InstallConfESPError where error.followedConfirmedWrite {
        installConfConsumed = true
        throw error
      }
    }
  }

  private struct CompletedEngineInstallPlan: Equatable, Sendable {
    let storeIdentifier: String
    let offsetBytes: UInt64
    let lengthBytes: UInt64
  }

  private struct RemovalJournal: Codable {
    let plan: OmarchyRemovalPlan
    let phase: String
  }

  /// The gate reads only the phase, so journals written by earlier versions,
  /// whose plan had fewer fields, still count as complete.
  private struct RemovalJournalPhase: Decodable {
    let phase: String
  }

  public final class ClosedEngineXPCServiceEndpoint:
    NSObject, ClosedEngineXPCService
  {
    private let server: ClosedEngineHelperServer
    private let version: String
    private let retirement: PackageInstalledAppRetirement

    /// - Parameter version: the helper's build version, or empty when it
    ///   carries none.
    public init(
      server: ClosedEngineHelperServer, version: String = "",
      retirement: PackageInstalledAppRetirement = PackageInstalledAppRetirement()
    ) {
      self.server = server
      self.version = version
      self.retirement = retirement
    }

    public func ping(reply: @escaping @Sendable (Bool) -> Void) {
      reply(true)
    }

    public func helperVersion(reply: @escaping @Sendable (String) -> Void) {
      reply(version)
    }

    public func retirePackageInstalledApps(reply: @escaping @Sendable (String) -> Void) {
      let retirement = retirement
      Task.detached {
        reply(PackageInstalledAppRetirement.summary(retirement.run()))
      }
    }

    public func removal(
      ticket: String, confirmation: String, machineOwner: String, password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      let server = server
      Task {
        do {
          guard ticket.isEmpty || UUID(uuidString: ticket) != nil,
            confirmation.utf8.count <= 256
          else { throw ClosedEngineHelperError.invalidOperation }
          let authorization =
            ticket.isEmpty
            ? nil : try MachineOwnerAuthorization(username: machineOwner, password: password)
          let result = try await server.removal(
            ticketID: UUID(uuidString: ticket), confirmation: confirmation,
            authorization: authorization)
          reply(try JSONEncoder().encode(result), nil)
        } catch {
          let message =
            (error as? RemovalFailure)?.message
            ?? "The helper could not prepare removal. Make sure this version of the app and its helper are installed and no installation is running."
          reply(try? JSONEncoder().encode(OmarchyRemovalReply(message: message)), nil)
        }
      }
    }

    public func submit(
      packageDirectory: FileHandle,
      operation: String,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      // NSXPCConnection.current() is only valid synchronously inside the
      // exported method, so the client proxy is captured before the Task.
      let client =
        NSXPCConnection.current()?
        .remoteObjectProxyWithErrorHandler { _ in
          // The peer exports no progress client: streaming stays off and the
          // authoritative reply path is untouched.
        } as? ClosedEngineProgressClient
      let sink = client.map(XPCJournalProgressSink.init(client:))
      let server = server
      Task {
        do {
          guard let operation = EngineHandoffOperation(rawValue: operation)
          else {
            throw ClosedEngineHelperError.invalidOperation
          }
          let authorization = try MachineOwnerAuthorization(
            username: machineOwner,
            password: password
          )
          let response = try await server.submit(
            packageDirectory: packageDirectory,
            authorization: authorization,
            operation: operation,
            progress: sink
          )
          reply(response, nil)
        } catch {
          reply(nil, EngineXPCErrorBridge.serviceError(for: error))
        }
      }
    }

    public func writeInstallConf(
      document: Data,
      storeIdentifier: String,
      offsetBytes: UInt64,
      lengthBytes: UInt64,
      machineOwner: String,
      password: Data,
      reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
      let server = server
      Task {
        do {
          let authorization = try MachineOwnerAuthorization(
            username: machineOwner,
            password: password
          )
          try await server.writeInstallConf(
            document: document,
            storeIdentifier: storeIdentifier,
            offsetBytes: offsetBytes,
            lengthBytes: lengthBytes,
            authorization: authorization
          )
          let (data, error) = InstallConfXPCCodec.encodeReply(error: nil, encrypt: true)
          reply(data, error)
        } catch {
          let encrypt = (try? InstallConf.parse(document))?.encrypt ?? true
          let (data, nsError) = InstallConfXPCCodec.encodeReply(
            error: error,
            encrypt: encrypt
          )
          reply(data, nsError)
        }
      }
    }
  }

  /// Install journals are named by the plan's binding digest, and removal
  /// returns the disk to the layout that plan was made from. Left in place,
  /// a reinstall at the same size finds its earlier journal complete and
  /// reports success without writing anything. They are kept for diagnosis
  /// under `retired-execution-journals/<removal ticket>`.
  func retireExecutionJournals(in workingDirectory: URL, removal: UUID) throws {
    let journals = workingDirectory.appendingPathComponent(
      "execution-journals", isDirectory: true)
    guard FileManager.default.fileExists(atPath: journals.path) else { return }
    let retired = workingDirectory.appendingPathComponent(
      "retired-execution-journals", isDirectory: true)
    if !FileManager.default.fileExists(atPath: retired.path) {
      try FileManager.default.createDirectory(
        at: retired, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    try FileManager.default.moveItem(
      at: journals,
      to: retired.appendingPathComponent(removal.uuidString, isDirectory: true))
  }

  public final class AuthenticatedEngineXPCListenerDelegate:
    NSObject, NSXPCListenerDelegate
  {
    private let clientCodeSigningRequirement: String
    private let endpoint: ClosedEngineXPCServiceEndpoint

    /// - Parameter helperVersion: the build version the helper reports; by
    ///   default the `CFBundleVersion` of its embedded Info.plist, or empty.
    public init(
      clientCodeSigningRequirement: String,
      server: ClosedEngineHelperServer,
      helperVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    ) throws {
      guard
        EngineCodeSigningRequirement.isValid(
          clientCodeSigningRequirement
        )
      else {
        throw ClosedEngineHelperError.invalidClientRequirement
      }
      self.clientCodeSigningRequirement = clientCodeSigningRequirement
      endpoint = ClosedEngineXPCServiceEndpoint(server: server, version: helperVersion)
    }

    public func listener(
      _ listener: NSXPCListener,
      shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
      connection.setCodeSigningRequirement(clientCodeSigningRequirement)
      connection.remoteObjectInterface = NSXPCInterface(
        with: ClosedEngineProgressClient.self
      )
      connection.exportedInterface = NSXPCInterface(
        with: ClosedEngineXPCService.self
      )
      connection.exportedObject = endpoint
      connection.activate()
      return true
    }
  }
#endif
