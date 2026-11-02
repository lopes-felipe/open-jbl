import Foundation

/// Serialization is reserved before the first suspension. A failed or cancelled send
/// poisons this single-use connection; a partial frame is never followed by another.
public actor FrameChannel {
    private let link: any Link
    private var busy = false
    private var poisoned = false
    public init(link: any Link) { self.link = link }

    func send(_ frame: Data) async throws {
        guard !poisoned else { throw LinkError.poisoned }
        guard !busy else { throw PolicyError.busy }
        busy = true
        defer { busy = false }
        let mtu = link.maximumWriteLength(.control)
        guard mtu > 0 else { throw LinkError.unavailable("Invalid control MTU") }
        do {
            for start in stride(from: 0, to: frame.count, by: mtu) {
                try Task.checkCancellation()
                let fragment = Data(frame[start..<min(start + mtu, frame.count)])
                try await withDeadline(.seconds(5)) { [link] in
                    try await link.write(fragment, to: .control)
                }
                guard !poisoned else { throw LinkError.poisoned }
            }
        } catch {
            poisoned = true
            await link.close()
            throw LinkError.poisoned
        }
    }

    public func close() async { poisoned = true; await link.close() }
}
