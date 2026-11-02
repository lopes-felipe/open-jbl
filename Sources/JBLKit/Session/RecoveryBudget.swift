import Foundation

struct RecoveryBudget: Sendable {
    struct Key: Hashable, Sendable {
        let firmware: String
        let component: String
        let operation: String
    }
    private var failures: [Key: Int] = [:]
    private let maximum = 128
    mutating func recordFailure(_ key: Key) -> Bool {
        if failures[key] == nil && failures.count == maximum { return false }
        let count = min(3, (failures[key] ?? 0) + 1)
        failures[key] = count
        return count < 3
    }
    func permits(_ key: Key) -> Bool {
        guard let count = failures[key] else { return failures.count < maximum }
        return count < 3
    }
    mutating func succeeded(_ key: Key) { failures.removeValue(forKey: key) }
    mutating func reset() { failures.removeAll() }
}
