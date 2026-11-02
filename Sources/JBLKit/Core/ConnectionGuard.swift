import Foundation

public struct AcquisitionContext: Sendable, Equatable {
    public var selectedAndPaired: Bool
    public var classicConnected: Bool
    public var controlNeeded: Bool
    public var awake: Bool
    public var permitted: Bool
    public var released: Bool

    public init(selectedAndPaired: Bool, classicConnected: Bool, controlNeeded: Bool,
                awake: Bool = true, permitted: Bool = true, released: Bool = false) {
        self.selectedAndPaired = selectedAndPaired; self.classicConnected = classicConnected
        self.controlNeeded = controlNeeded; self.awake = awake; self.permitted = permitted; self.released = released
    }

    public var allowsAcquisition: Bool {
        selectedAndPaired && classicConnected && controlNeeded && awake && permitted && !released
    }
}

/// Shared by a UI/coordinator and the transport thread. Revocation is synchronous.
public final class AcquisitionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var context: AcquisitionContext
    public init(_ context: AcquisitionContext) { self.context = context }
    public func update(_ value: AcquisitionContext) { lock.withLock { context = value } }
    public var allowsAcquisition: Bool { lock.withLock { context.allowsAcquisition } }
}
