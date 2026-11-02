import Foundation

public enum OperationReply: Sendable, Equatable {
    /// A protocol response is not a confirmed setting change.
    case response([RaceFrame])
    case confirmedMode(TourPro3Sound.ListeningMode, changed: Bool)
}

/// Guarded single-use connection: one bounded request at a time. DeviceSession
/// owns the state store; protocol capabilities still require M1 evidence.
public actor GuardedSession {
    private let link: any Link
    private let channel: FrameChannel
    private let catalog: OperationCatalog
    private var context: PolicyContext
    private let deriveVerification: Bool
    private var identityBinding: DeviceReference?
    private let permit: AcquisitionPermit
    private var reader: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var decoder = RaceCodec()
    private let clock = ContinuousClock()
    private let epoch = ContinuousClock.now
    private var pending: (UUID, OperationSpec, PendingSlot<OperationReply>)?
    private var received: [RaceFrame] = []
    private var closed = false
    private var lease = false
    private var started = false
    private var earbudFirmware: String?
    private var caseFirmware: String?
    private var verifiedEarbudFirmware: String?
    private var diagnostics: DiagnosticRing
    private var stateEvents: OrderedMailbox?
    private var responseSeen = false

    /// One ordered state consumer, independent of transaction completion. The
    /// mailbox carries exact decoded frames as data events, never outbound work.
    public func attachStateEvents() throws -> OrderedMailbox {
        guard stateEvents == nil else { throw LinkError.multipleConsumers }
        let mailbox = OrderedMailbox(generation: link.generation)
        stateEvents = mailbox
        if closed { mailbox.enqueue(.closed(.disconnected)) }
        return mailbox
    }

    public var generation: UInt64 { link.generation }
    public var isActive: Bool { started && !closed && permit.allowsAcquisition }
    public func diagnosticSnapshot() -> DiagnosticSnapshot { diagnostics.snapshot() }
    public func setDiagnosticRecording(_ enabled: Bool) { diagnostics.setEnabled(enabled) }

    private func record(_ stage: ValidationStage, _ result: DiagnosticResult,
                        operation: String? = nil, direction: DiagnosticDirection? = nil,
                        frame: RaceFrame? = nil, rule: ValidationRule? = nil) {
        // Only canonical catalog names may enter the log, including rejected requests.
        let safeName = operation.flatMap { catalog[$0]?.name }
        diagnostics.append(elapsed: epoch.duration(to: clock.now), generation: link.generation,
                           operation: safeName, stage: stage, result: result,
                           direction: direction, frame: frame, rule: rule)
    }

    /// Bounded M1 observations, including validated events outside a transaction.
    /// Production write gates are derived from the active binding and captured
    /// earbud firmware. Case versions and caller-supplied booleans never grant it.
    public func observedFirmware() -> (earbuds: String?, chargingCase: String?) {
        (earbudFirmware, caseFirmware)
    }

    public init(link: any Link, permit: AcquisitionPermit, context: PolicyContext,
                recordDiagnostics: Bool = false) {
        self.link = link; self.channel = FrameChannel(link: link)
        self.permit = permit; self.context = context; self.catalog = .production
        self.context.identityVerified = false; self.context.firmwareKnown = false
        self.context.firmwareVersion = nil
        self.deriveVerification = true
        self.diagnostics = DiagnosticRing(enabled: recordDiagnostics)
    }
    init(link: any Link, permit: AcquisitionPermit, context: PolicyContext, catalog: OperationCatalog,
         recordDiagnostics: Bool = false) {
        self.link = link; self.channel = FrameChannel(link: link)
        self.permit = permit; self.context = context; self.catalog = catalog
        self.deriveVerification = false // synthetic tests only; not public API
        self.diagnostics = DiagnosticRing(enabled: recordDiagnostics)
    }

    deinit {
        stateEvents?.enqueue(.closed(.disconnected))
        reader?.cancel()
        expiry?.cancel()
        let channel = channel
        Task { await channel.close() }
    }

    public func start() async throws {
        guard !closed else { throw LinkError.disconnected }
        guard !started else { throw PolicyError.busy }
        guard permit.allowsAcquisition else { throw PolicyError.connectionGuard }
        // With an empty catalog, even opening a channel has no purpose.
        guard !context.model.enabledOperations.isEmpty else { throw PolicyError.missingCapture }
        started = true
        reader = Task { [weak self, link] in
            do {
                while let event = try await link.events.next() {
                    guard let self else { return }
                    await self.ingest(event)
                }
            } catch { await self?.fail(.disconnected) }
        }
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await self?.expirePartial()
            }
        }
        do {
            record(.connection, .started)
            try await link.open()
            guard !closed, permit.allowsAcquisition else {
                await stop()
                throw PolicyError.connectionGuard
            }
            identityBinding = link.boundDevice
            updateVerification()
            record(.connection, .passed)
        } catch {
            record(.connection, .failed, rule: .openFailed)
            await stop(); throw error
        }
    }

    public func perform(_ request: OperationRequest) async throws -> OperationReply {
        // Policy is evaluated before any transport action.
        updateVerification()
        let spec: OperationSpec
        do { spec = try SendPolicy.validate(request, in: catalog, context: context).0 }
        catch {
            record(.policy, .failed, operation: request.name, rule: .policyRejected)
            throw error
        }
        guard started, !closed else { throw LinkError.disconnected }
        guard permit.allowsAcquisition else { throw PolicyError.connectionGuard }
        guard !lease else { throw PolicyError.busy }
        diagnostics.clearFailure()
        lease = true
        defer { lease = false }
        do {
            return try await withDeadline(spec.deadlines.total) {
                if let target = TourPro3ModeTests.target(for: request.name) {
                    return try await self.performModeTest(request, target: target)
                }
                return try await self.transact(request)
            }
        } catch {
            if error as? LinkError == .timedOut {
                let stage = diagnostics.lastFailure?.stage ?? .response
                record(stage, .failed, operation: spec.name, rule: .timedOut)
            }
            await stop(); throw error
        }
    }

    private func transact(_ request: OperationRequest, stage: ValidationStage = .response) async throws -> OperationReply {
        updateVerification()
        let (spec, bytes) = try SendPolicy.validate(request, in: catalog, context: context)
        guard !closed, permit.allowsAcquisition else { throw PolicyError.connectionGuard }
        let id = UUID()
        let slot = PendingSlot<OperationReply>()
        pending = (id, spec, slot)
        received = []
        responseSeen = false
        var transmitted = false
        do {
            record(.transmission, .started, operation: spec.name, direction: .outbound,
                   frame: try RaceFrame.exact(bytes))
            try await channel.send(bytes)
            transmitted = true
            record(.transmission, .passed, operation: spec.name)
            let result = try await withDeadline(spec.responseDeadline) { try await slot.wait() }
            if deriveVerification && request.name == "earbud-firmware" {
                guard case .response(let frames) = result,
                      frames.contains(where: { $0.kind == .response && $0.payload == Data([0]) }),
                      let report = frames.compactMap(TourPro3Telemetry.decodeFirmware)
                        .first(where: { $0.component == .earbuds }) else {
                    throw LinkError.unavailable("Unrecognized firmware reply")
                }
                verifiedEarbudFirmware = report.version
                updateVerification()
            }
            return result
        } catch {
            // No uncorrelated matcher is reused after cancellation/timeout.
            // This M1 harness conservatively tears down instead of recovering.
            let failureStage: ValidationStage
            if !transmitted { failureStage = .transmission }
            else if case .responseThenIndication = spec.completion {
                failureStage = responseSeen ?
                    .stateNotification : .acknowledgement
            } else { failureStage = stage }
            let rule: ValidationRule = error is CancellationError || error as? LinkError == .cancelled ?
                .cancelled : (error as? LinkError == .timedOut ? .timedOut : .transportFailed)
            record(failureStage, .failed, operation: spec.name, rule: rule)
            await stop()
            throw error
        }
    }

    private func performModeTest(_ request: OperationRequest,
                                 target: TourPro3Sound.ListeningMode) async throws -> OperationReply {
        let before = try await transact(OperationRequest("listening-mode"), stage: .baseline)
        guard case .response(let initialFrames) = before,
              let initial = initialFrames.compactMap(TourPro3Sound.decodeListeningReadback).first,
              TourPro3ModeTests.matchesCapturedProfile(initial) else {
            record(.baseline, .failed, operation: request.name, rule: .capturedBaseline)
            throw ModeTestError.baselineMismatch
        }
        record(.baseline, .passed, operation: request.name, rule: .capturedBaseline)
        if initial.mode == target { return .confirmedMode(target, changed: false) }
        let write = try await transact(request)
        guard case .response(let frames) = write,
              frames.contains(where: { TourPro3ModeTests.successfulReply($0, mode: target) }) else {
            record(.acknowledgement, .failed, operation: request.name, rule: .capturedAcknowledgement)
            throw ModeTestError.acknowledgementMismatch
        }
        record(.acknowledgement, .passed, operation: request.name, rule: .capturedAcknowledgement)
        guard frames.compactMap(TourPro3Sound.decodeListeningReport).contains(where: {
                  $0.mode == target && $0.opaqueFields == Data(initial.opaqueFields.prefix(2))
              }) else {
            record(.stateNotification, .failed, operation: request.name, rule: .capturedNotification)
            throw ModeTestError.stateNotificationMismatch
        }
        record(.stateNotification, .passed, operation: request.name, rule: .capturedNotification)
        let readback = try await transact(OperationRequest("listening-mode"), stage: .readback)
        guard case .response(let finalFrames) = readback,
              let final = finalFrames.compactMap(TourPro3Sound.decodeListeningReadback).first,
              final.mode == target, TourPro3ModeTests.matchesCapturedProfile(final) else {
            record(.readback, .failed, operation: request.name, rule: .capturedReadback)
            throw ModeTestError.unconfirmed
        }
        record(.readback, .passed, operation: request.name, rule: .capturedReadback)
        return .confirmedMode(target, changed: true)
    }

    private func updateVerification() {
        guard deriveVerification else { return }
        let binding = link.boundDevice
        let addressParts = binding?.address.split(whereSeparator: { $0 == ":" || $0 == "-" }) ?? []
        context.identityVerified = identityBinding != nil && binding == identityBinding &&
            binding?.name == ModelCatalog.tourPro3.name && context.model.name == ModelCatalog.tourPro3.name &&
            context.model.pids == ModelCatalog.tourPro3.pids &&
            context.model.casePID == ModelCatalog.tourPro3.casePID && context.model.support == .verified &&
            addressParts.count == 6 && addressParts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
        context.firmwareKnown = context.identityVerified && verifiedEarbudFirmware == "6.0.1" &&
            earbudFirmware == verifiedEarbudFirmware
        context.firmwareVersion = context.firmwareKnown ? verifiedEarbudFirmware : nil
    }

    private func ingest(_ item: SequencedEvent) {
        guard item.generation == link.generation, !closed else { return }
        switch item.event {
        case .data(.control, let bytes):
            do {
                for frame in try decoder.ingest(bytes, at: epoch.duration(to: clock.now)) {
                    guard !closed else { break }
                    accept(frame)
                }
            } catch { fail(.poisoned); Task { await self.channel.close() } }
        case .closed(let error): fail(error ?? .disconnected)
        default: break
        }
    }

    private func accept(_ frame: RaceFrame) {
        guard !closed else { return }
        if let stateEvents {
            // This is synchronous on the single ingress consumer. No callback
            // task can reorder a frame relative to transaction completion.
            do {
                if !stateEvents.enqueue(.data(.control, try frame.encoded())) {
                    fail(.overflow)
                    Task { await self.channel.close() }
                    return
                }
            } catch {
                fail(.poisoned)
                Task { await self.channel.close() }
                return
            }
        }
        if let report = TourPro3Telemetry.decodeFirmware(frame) {
            switch report.component {
            case .earbuds: earbudFirmware = report.version
            case .chargingCase: caseFirmware = report.version
            default: break
            }
            updateVerification()
        }
        guard let (_, spec, slot) = pending else {
            record(.response, .unmatched, direction: .inbound, frame: frame)
            return
        }
        func matches(_ candidate: RaceFrame, _ id: UInt16, _ kind: RaceFrame.Kind,
                     _ role: UInt8? = nil, offset: Int = 0) -> Bool {
            guard candidate.id == id, candidate.kind == kind else { return false }
            guard let role else { return true }
            guard offset >= 0, offset < candidate.payload.count else { return false }
            return candidate.payload[candidate.payload.index(candidate.payload.startIndex, offsetBy: offset)] == role
        }
        let complete: Bool
        let diagnosticStage: ValidationStage = frame.kind == .response ? .acknowledgement : .stateNotification
        func trace(_ matched: Bool) {
            record(diagnosticStage, matched ? .matched : .unmatched, operation: spec.name,
                   direction: .inbound, frame: frame)
        }
        switch spec.completion {
        case .response(let id):
            let matched = matches(frame, id, .response); trace(matched)
            guard matched else { return }
            responseSeen = true
            received.append(frame); complete = true
        case .indication(let id, let kind, let role, let offset):
            let matched = matches(frame, id, kind, role, offset: offset); trace(matched)
            guard matched else { return }
            received.append(frame); complete = true
        case .responseThenIndication(let response, let indication, let kind, let role, let offset):
            let matched = matches(frame, response, .response) || matches(frame, indication, kind, role, offset: offset)
            trace(matched)
            guard matched else { return }
            if matches(frame, response, .response) { responseSeen = true }
            // Keep at most one response and one role-matched indication. Repeated
            // notifications must not grow storage while the other half is missing.
            if !received.contains(where: { $0.kind == frame.kind && $0.id == frame.id }) {
                received.append(frame)
            }
            complete = received.contains { $0.kind == .response && $0.id == response } &&
                received.contains { matches($0, indication, kind, role, offset: offset) }
        }
        if complete {
            pending = nil
            slot.finish(.success(.response(received)))
            received = []
        }
    }

    private func expirePartial() {
        guard !closed else { return }
        do { try decoder.expire(at: epoch.duration(to: clock.now)) }
        catch { fail(.poisoned); Task { await self.channel.close() } }
    }

    private func fail(_ error: LinkError) {
        if !closed { stateEvents?.enqueue(.closed(error)) }
        closed = true
        pending?.2.finish(.failure(error))
        pending = nil; received = []
        earbudFirmware = nil; caseFirmware = nil; verifiedEarbudFirmware = nil
        identityBinding = nil
        if deriveVerification {
            context.identityVerified = false; context.firmwareKnown = false; context.firmwareVersion = nil
        }
        expiry?.cancel()
    }

    public func stop() async {
        if !closed { record(.teardown, .started) }
        fail(.disconnected)
        reader?.cancel(); reader = nil
        expiry?.cancel(); expiry = nil
        await channel.close()
    }
}
