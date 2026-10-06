import ExternalAccessory
import Foundation
import RedlineCore

/// One External Accessory session (`EASession`) to the MX+ and the thread
/// its streams run on.
///
/// Apple's rules for these streams: schedule them on a run loop that is
/// actually running (never a GCD queue or a Swift-concurrency executor),
/// touch them only from that run loop's thread, and tear down in the reverse
/// order of setup. So the session owns one `StreamThread`; every stream call,
/// every `StreamDelegate` event and every `StreamPump` call happens on it.
///
/// It carries bytes only. Everything written comes from `StreamPump.send`,
/// whose only caller is `AccessoryStreamTransport.write`, whose only caller
/// is `ELM327Session` (after the read-only gate).
final class EAStreamSession: NSObject, AccessoryStreamSession, StreamDelegate, @unchecked Sendable {
    /// Identifies the accessory for this connection only (iOS assigns a new
    /// one on every reconnect).
    let connectionID: Int
    let details: TransportLinkDetails

    // Confined to `thread` once started.
    private let session: EASession
    private var pump: StreamPump?
    private let thread: StreamThread
    private let invalidated = Locked(false)

    init(session: EASession, accessory: AccessoryDescriptor, protocolString: String, declared: [String]) {
        self.session = session
        self.connectionID = accessory.connectionID
        self.details = TransportLinkDetails(items: [
            .init("Transport", TransportKind.externalAccessory.title),
            .init("Session protocol", protocolString),
            .init("Redline declares", declared.joined(separator: ", ")),
        ] + accessory.detailItems)
        self.thread = StreamThread(label: "Redline accessory I/O")
        super.init()
        thread.start()
    }

    deinit {
        // Normally `invalidate()` already stopped the thread; never leave a
        // run loop spinning for a session nobody holds.
        if !invalidated.withLock({ $0 }) { thread.requestStop() }
    }

    // MARK: AccessoryStreamSession

    func start(makePump: @escaping @Sendable (any ByteInputStream, any ByteOutputStream) -> StreamPump) {
        perform { [self] in
            guard let input = session.inputStream, let output = session.outputStream else {
                let pump = makePump(NoInput(), NoOutput())
                self.pump = pump
                pump.fail(.connectFailed("The accessory session has no data streams"))
                return
            }
            let pump = makePump(input, output)
            self.pump = pump
            input.delegate = self
            output.delegate = self
            input.schedule(in: .current, forMode: .default)
            output.schedule(in: .current, forMode: .default)
            input.open()
            output.open()
        }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        guard !invalidated.withLock({ $0 }) else { return }
        thread.perform(block)
    }

    func invalidate() {
        let first = invalidated.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        thread.perform { [self] in
            // Mirror of setup: close, unschedule, drop the delegate.
            for stream in [session.inputStream as Stream?, session.outputStream as Stream?] {
                guard let stream else { continue }
                stream.close()
                stream.remove(from: .current, forMode: .default)
                stream.delegate = nil
            }
            pump = nil
            thread.stop()
        }
    }

    /// EAAccessoryDidDisconnect for this accessory (main thread).
    func accessoryDisconnected() {
        perform { [self] in
            pump?.fail(.disconnected("The OBD adapter disconnected from the iPhone (accessory notification)"))
        }
    }

    // MARK: StreamDelegate (on `thread`)

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard let pump else { return }
        let side: StreamPump.Side = aStream === session.inputStream ? .input : .output
        pump.handle(eventCode, on: side, errorDescription: aStream.streamError?.localizedDescription)
    }
}

/// A thread running its own run loop, on which the accessory streams are
/// scheduled (one per session).
final class StreamThread: @unchecked Sendable {
    private let ready = NSCondition()
    private var runLoop: CFRunLoop?
    private var finished = false // touched only on this thread
    private var thread: Thread?

    init(label: String) {
        // The thread keeps this object alive until its run loop stops.
        let thread = Thread { self.main() }
        thread.name = label
        thread.qualityOfService = .userInitiated
        self.thread = thread
    }

    func start() {
        thread?.start()
    }

    private func main() {
        ready.lock()
        runLoop = CFRunLoopGetCurrent()
        ready.broadcast()
        ready.unlock()
        // A far-future timer keeps the run loop alive while it has no
        // streams; performed blocks and stream events wake it.
        let keepAlive = Timer(timeInterval: 86_400, repeats: true) { _ in }
        RunLoop.current.add(keepAlive, forMode: .default)
        while !finished {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        keepAlive.invalidate()
        thread = nil
    }

    /// Runs `block` on this thread (thread-safe; CFRunLoop is).
    func perform(_ block: @escaping @Sendable () -> Void) {
        ready.lock()
        while runLoop == nil { ready.wait() }
        let loop = runLoop
        ready.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Asks the thread to finish (from any thread).
    func requestStop() {
        perform { [self] in stop() }
    }

    /// Call on this thread: ends the run loop and the thread.
    func stop() {
        finished = true
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}

/// Placeholders when an `EASession` unexpectedly has no streams.
private final class NoInput: ByteInputStream {
    var hasBytesAvailable: Bool { false }
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int { -1 }
}

private final class NoOutput: ByteOutputStream {
    var hasSpaceAvailable: Bool { false }
    func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int { -1 }
}
