import Foundation
import CoreFoundation

/// Process-lifetime run loop. Only transport facades enqueue work here.
/// The run-loop reference is initialized before publication and never changes.
final class IOBluetoothThread: @unchecked Sendable {
    static let shared = IOBluetoothThread()
    private let loop: CFRunLoop
    private let thread: Thread

    private final class Startup: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        var loop: CFRunLoop?
    }

    private init() {
        let startup = Startup()
        thread = Thread {
            let loop = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(loop, source, .defaultMode)
            startup.loop = loop
            startup.ready.signal()
            CFRunLoopRun()
        }
        thread.name = "io.github.lopesfelipe.OpenJBL.bluetooth"
        thread.start()
        startup.ready.wait()
        loop = startup.loop!
    }

    func perform(_ operation: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, operation)
        CFRunLoopWakeUp(loop)
    }
}
