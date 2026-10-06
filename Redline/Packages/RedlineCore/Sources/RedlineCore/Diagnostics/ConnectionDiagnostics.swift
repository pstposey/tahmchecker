import Foundation

/// One command of the adapter initialization / vehicle-detection sequence,
/// as it actually happened. Shown in the debug report so a hardware session
/// can be compared step by step across adapters.
public struct InitStepRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// The adapter replied (the reply may still be "?" or an error text).
        case answered
        /// No usable reply: timeout, link loss, refusal or cancellation.
        case failed
    }

    public let command: String
    public let outcome: Outcome
    /// Reply lines joined with " | ", or the error.
    public let detail: String
    public let roundTripMs: Double?
    public let at: Date

    public init(command: String, outcome: Outcome, detail: String, roundTripMs: Double?, at: Date) {
        self.command = command
        self.outcome = outcome
        self.detail = detail
        self.roundTripMs = roundTripMs
        self.at = at
    }
}

/// Collects `InitStepRecord`s from `ELMInitializer` (which runs off the main
/// actor) for the engine to read synchronously.
public final class InitStepRecorder: Sendable {
    public static let capacity = 64
    private let records = Locked<[InitStepRecord]>([])

    public init() {}

    public func record(_ record: InitStepRecord) {
        records.withLock {
            $0.append(record)
            if $0.count > Self.capacity { $0.removeFirst($0.count - Self.capacity) }
        }
    }

    public var all: [InitStepRecord] { records.withLock { $0 } }

    public func reset() { records.withLock { $0.removeAll() } }
}

/// A connection-state change, for validating connect / disconnect /
/// reconnect / cancellation behaviour on real hardware.
public struct StateTransition: Sendable, Equatable {
    public let at: Date
    public let state: EngineState

    public init(at: Date, state: EngineState) {
        self.at = at
        self.state = state
    }

    public var summary: String {
        state.title + (state.detail.map { " — \($0)" } ?? "")
    }
}
