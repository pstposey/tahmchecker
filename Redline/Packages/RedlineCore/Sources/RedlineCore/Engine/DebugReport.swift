import Foundation

extension TelemetryEngine {
    /// Plain-text snapshot of everything needed to diagnose a hardware
    /// session: link, adapter, protocol, supported PIDs, polling rates,
    /// latency, and the raw command log. Designed to be pasted into an issue
    /// or chat. Contains no location or personal data; VIN is not read.
    public func debugReport(appVersion: String, logLines: Int = 400) -> String {
        var out: [String] = []
        let now = ContinuousClock().now
        out.append("REDLINE DEBUG REPORT")
        out.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("App: \(appVersion)")
        out.append("State: \(state.title)\(state.detail.map { " — \($0)" } ?? "")")
        if let id = transportIdentity {
            out.append("Source: \(id.kind == .simulated ? "SIMULATION" : id.kind.rawValue) — \(id.name) [\(id.identifier)]")
            out.append("Transport: \(id.kind.title)")
            let identification = AdapterIdentifier.identify(identity: id, linkDetails: linkDetails, adapterInfo: adapterInfo)
            out.append("Adapter identified as: \(identification.summary) [name-based, unverified]")
        }

        out.append("")
        out.append("== Link ==")
        for item in linkDetails?.items ?? [] { out.append("\(item.key): \(item.value)") }

        out.append("")
        out.append("== Adapter ==")
        if let a = adapterInfo {
            out.append("ATZ banner: \(a.resetBanner ?? "-")")
            out.append("Reported version: \(a.reportedVersion ?? "-") (as claimed by the adapter)")
            out.append("ATI: \(a.identification ?? "-")")
            out.append("AT@1: \(a.deviceDescription ?? "-")")
            out.append("ATRV: \(a.adapterVoltage ?? "-")")
            out.append("Protocol: \(a.obdProtocol.map { "\($0.rawValue) \($0.displayName)" } ?? "-")\(a.protocolAutoDetected ? " (auto)" : "")")
            out.append("ATDP: \(a.protocolDescription ?? "-")")
            out.append("Responders: \(a.responders.map(\.description).joined(separator: ", "))")
            out.append("Physical header: \(a.physicalRequestHeader ?? "off (functional 7DF)")")
            out.append("Adapter protocol setting before init: \(a.storedProtocolBeforeInit ?? "-")")
            out.append("Persistent adapter settings changed this session: \(a.persistentAdapterWrites.isEmpty ? "none" : a.persistentAdapterWrites.joined(separator: ", ")) (never vehicle)")
        } else {
            out.append("(not initialized)")
        }
        if let o = effectiveOptions {
            out.append("Options: physicalAddressing=\(o.physicalAddressing) responseCountHint=\(o.responseCountHint)")
        }

        out.append("")
        out.append("== Initialization (current link) ==")
        let steps = initSteps
        if steps.isEmpty { out.append("(no commands yet)") }
        let clockTime = DateFormatter()
        clockTime.locale = Locale(identifier: "en_US_POSIX")
        clockTime.dateFormat = "HH:mm:ss.SSS"
        for step in steps {
            let rtt = step.roundTripMs.map { String(format: "%.0f ms", $0) } ?? "-"
            out.append("\(clockTime.string(from: step.at))  \(step.command)  \(step.outcome.rawValue)  \(rtt)  \(step.detail)")
        }

        out.append("")
        out.append("== Connection state history (last \(stateHistory.count)) ==")
        for t in stateHistory {
            out.append("\(clockTime.string(from: t.at))  \(t.summary)")
        }

        out.append("")
        out.append("== Supported service 01 PIDs ==")
        if let support {
            for ecu in support.respondingECUs {
                let pids = (support.byECU[ecu] ?? []).sorted().map(Hex.byteString).joined(separator: " ")
                out.append("\(ecu): \(pids)")
            }
        } else {
            out.append("(not discovered)")
        }

        out.append("")
        out.append("== Polling (\(pollingPreset.title)) ==")
        for id in polledChannels.sorted() {
            guard let ch = store.channel(id) else { continue }
            let target = 1 / ch.descriptor.pollingClass.targetInterval.seconds
            let observed = ch.observedRateHz.map { String(format: "%.1f", $0) } ?? "-"
            let value = ch.latest.map { String(format: "%.3f ", $0.value) + ch.descriptor.quantity.baseUnitSymbol } ?? "--"
            out.append("\(ch.descriptor.shortName)  target \(String(format: "%.1f", target)) Hz  observed \(observed) Hz  "
                       + "samples \(ch.sampleCount)  invalid \(ch.invalidCount)  last \(value)")
        }
        if let boost = store.channel(.boost), let b = boost.latest {
            out.append("BOOST (calculated): \(String(format: "%.1f kPa", b.value)) — \(b.derivation ?? "")")
        }

        let p = monitor.snapshot(now: now)
        out.append("")
        out.append("== Performance (last \(Int(p.windowSeconds)) s) ==")
        func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "-" }
        out.append(String(format: "Success %.1f/s  Fail %.1f/s", p.successPerSecond, p.failurePerSecond))
        out.append("Totals: requests \(p.totalRequests), failures \(p.totalFailures), timeouts \(p.totalTimeouts)")
        out.append("Round trip: last \(ms(p.lastRoundTripMs)) median \(ms(p.medianRoundTripMs)) p95 \(ms(p.p95RoundTripMs)) max \(ms(p.maxRoundTripMs))")
        out.append("First byte: median \(ms(p.medianFirstByteMs))  Decode: median \(ms(p.medianDecodeMs))  Publish: median \(ms(p.medianPublishMs))")
        out.append("Queue depth: \(p.queueDepth)")
        for c in p.perCommand {
            out.append("  \(c.command)  \(String(format: "%.1f", c.rateHz)) Hz  ok \(c.successesInWindow)  "
                       + "fail \(c.failuresInWindow)  median \(ms(c.medianRoundTripMs))")
        }

        out.append("")
        out.append("== Raw log (last \(logLines)) ==")
        out.append(log.exportText(last: logLines))
        return out.joined(separator: "\n")
    }
}
