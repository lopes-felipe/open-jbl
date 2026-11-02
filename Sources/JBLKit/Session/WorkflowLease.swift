import Foundation

public struct WorkflowLease: Sendable, Equatable {
    public let kind: WorkflowKind
    let id: UUID
}

/// Definitions remain source-only. Declaring an operation here never authorizes
/// it: every step still goes through the production GuardedSession catalog.
struct WorkflowPlan: Sendable {
    let kind: WorkflowKind
    let steps: Set<String>
    let stop: String?

    static func captured(_ kind: WorkflowKind) -> WorkflowPlan? {
        // Find My Buds has no verified start/stop/cancellation fixture yet.
        // A future plan must declare all steps and its proven abort point here.
        nil
    }
}
