import Foundation
import Testing
@testable import RedlineCore

/// Debug-report diagnostics used to compare adapters on real hardware:
/// per-command initialization results and the connection-state timeline.
@MainActor
@Suite("Connection diagnostics")
struct ConnectionDiagnosticsTests {
    @Test func initStepsAreRecordedInOrderWithTimings() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        let steps = engine.initSteps
        #expect(Array(steps.map(\.command).prefix(12)) == [
            "ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATI", "AT@1", "ATRV", "ATDPN", "0100", "ATDPN", "ATDP",
        ])
        #expect(steps.allSatisfy { $0.outcome == .answered && $0.roundTripMs != nil })
        #expect(steps.first?.detail.contains("ELM327") == true)
        let report = engine.debugReport(appVersion: "t")
        #expect(report.contains("== Initialization (current link) =="))
        #expect(report.contains("ATZ  answered"))
        await engine.stop()
    }

    @Test func failedInitStepIsRecorded() async throws {
        // The adapter answers ATZ, then goes silent: the report must show
        // which command failed and why, not just "Disconnected".
        let t = ScriptedTransport { cmd in
            cmd == "ATZ" ? .text("\r\rELM327 v1.5\r\r>", after: .milliseconds(5)) : .silence
        }
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.autoReconnect = false
        engine.start(transport: t)
        try await waitUntil(seconds: 15) {
            if case .disconnected = engine.state { return true }
            return false
        }
        let steps = engine.initSteps
        #expect(steps.map(\.command) == ["ATZ", "ATE0"])
        #expect(steps.first?.outcome == .answered)
        #expect(steps.last?.outcome == .failed)
        #expect(steps.last?.detail.contains("Timed out") == true)
        await engine.stop()
    }

    @Test func stateHistoryRecordsTheConnectionLifecycle() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        await engine.stop()
        let titles = engine.stateHistory.map(\.state.title)
        let expected = ["Connecting", "Initializing adapter", "Contacting vehicle", "Detecting supported data",
                        "Connected", "Not connected"]
        // `expected` appears in order (other states may be interleaved).
        var it = titles.makeIterator()
        #expect(expected.allSatisfy { e in
            while let t = it.next() { if t == e { return true } }
            return false
        }, "history: \(titles)")
        #expect(engine.debugReport(appVersion: "t").contains("== Connection state history"))
    }

    @Test func diagnosticsAreBounded() {
        let recorder = InitStepRecorder()
        for i in 0..<(InitStepRecorder.capacity + 10) {
            recorder.record(InitStepRecord(command: "01\(i)", outcome: .answered, detail: "", roundTripMs: 1, at: Date()))
        }
        #expect(recorder.all.count == InitStepRecorder.capacity)
        #expect(recorder.all.last?.command == "01\(InitStepRecorder.capacity + 9)")
        recorder.reset()
        #expect(recorder.all.isEmpty)
    }
}
