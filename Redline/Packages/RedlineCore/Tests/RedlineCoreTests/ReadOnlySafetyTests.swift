import Foundation
import Testing
@testable import RedlineCore

/// Enforces the Milestone 1 boundary: Redline is strictly read-only toward the
/// vehicle and never changes adapter configuration beyond the documented set.
/// See docs/SAFETY.md. If a test here fails because you added an outbound
/// path, stop and review it against SAFETY.md before changing the test.
@Suite("Read-only safety boundary")
struct ReadOnlySafetyTests {
    // MARK: Services

    static let readOnly: Set<UInt8> = [0x01, 0x02, 0x03, 0x06, 0x07, 0x09, 0x0A]

    @Test func onlySAEReadServicesAreTransmittable() {
        #expect(CommandSafetyPolicy.readOnlyServices == Self.readOnly)
        for service in 0...0xFF {
            let request = Hex.byteString(UInt8(service)) + "00"
            let allowed = CommandSafetyPolicy.evaluateTransmission(request).isAllowed
            #expect(allowed == Self.readOnly.contains(UInt8(service)), "service \(Hex.byteString(UInt8(service)))")
            #expect(CommandSafetyPolicy.evaluateConsoleCommand(request).isAllowed == allowed)
        }
    }

    /// Named write/control requests, each of which must be refused.
    static let dangerousRequests: [(String, String)] = [
        ("04", "SAE J1979 clear DTCs / freeze frame / readiness"),
        ("0801", "SAE J1979 on-board system/actuator control"),
        ("1001", "UDS DiagnosticSessionControl"), ("1003", "UDS extended session"),
        ("1101", "UDS ECUReset hard reset"), ("1103", "UDS ECUReset soft reset"),
        ("14FFFFFF", "UDS ClearDiagnosticInformation"),
        ("2701", "UDS SecurityAccess request seed"), ("27020000", "UDS SecurityAccess send key"),
        ("2803", "UDS CommunicationControl"),
        ("2C01F200", "UDS DynamicallyDefineDataIdentifier"),
        ("2EF19000", "UDS WriteDataByIdentifier (coding/configuration)"),
        ("2F00010300", "UDS InputOutputControl (actuators)"),
        ("3101FF00", "UDS RoutineControl start"), ("3102FF00", "UDS RoutineControl stop"),
        ("34004400", "UDS RequestDownload (reflash)"), ("35004400", "UDS RequestUpload"),
        ("3601", "UDS TransferData"), ("37", "UDS RequestTransferExit"),
        ("3D14", "UDS WriteMemoryByAddress"), ("3B9001", "KWP WriteDataByLocalIdentifier"),
        ("3001", "KWP InputOutputControlByLocalIdentifier"), ("3E00", "UDS TesterPresent"),
        ("8502", "UDS ControlDTCSetting"), ("8701", "UDS LinkControl"),
        ("22F190", "UDS ReadDataByIdentifier (not needed in Milestone 1)"),
        ("19020F", "UDS ReadDTCInformation (not needed in Milestone 1)"),
        ("2300", "UDS ReadMemoryByAddress"),
    ]

    @Test func writeAndControlServicesAreRefused() {
        for (request, what) in Self.dangerousRequests {
            #expect(!CommandSafetyPolicy.evaluateTransmission(request).isAllowed, "\(request) — \(what)")
            #expect(!CommandSafetyPolicy.evaluateConsoleCommand(request).isAllowed, "\(request) — \(what)")
        }
    }

    // MARK: Adapter commands

    /// ELM327 commands that could change persistent adapter configuration,
    /// transmit arbitrary/raw CAN frames, send bus wake-up or keep-alive
    /// traffic, or flood the link. None may be transmitted.
    static let dangerousATCommands: [String] = [
        "ATPP0CSV23", "ATPP0CON", "ATPP0COFF", "ATPPFFOFF", // programmable parameters (EEPROM)
        "ATSD12", "ATCV1250", "ATCV0000",                   // save data byte, calibrate voltage (EEPROM)
        "ATBRD23", "ATBRT20",                               // UART baud rate
        "ATLP",                                             // low power
        "ATSP6", "ATSPA6", "ATTP6", "ATTPA6",               // fixed/stored protocol other than auto
        "ATSH7DF", "ATSH000", "ATSH123", "ATSH18DB33F1", "ATSH7E8", // arbitrary CAN headers
        "ATCAF0", "ATCAF1", "ATAL", "ATNL", "ATR0", "ATRTR", "ATV1", // raw frames, long/no-response sends
        "ATCF7E8", "ATCM7FF", "ATCRA7E8", "ATCP18",         // filters / priority
        "ATFCSH7E0", "ATFCSD300000", "ATFCSM1",             // flow control
        "ATMA", "ATMR10", "ATMT10", "ATBD", "ATDM1",        // monitors / buffer dump
        "ATSW00", "ATWM8113F13E", "ATSI", "ATFI", "ATBI", "ATKW0", "ATIB10", "ATIIA13", // bus init / wake-up / keep-alive
        "ATD", "ATWS", "ATE1", "ATH0", "ATS0", "ATL1", "ATAT0", "ATST00", // not used by Redline
        "ATJE", "ATJS", "ATCSM0", "ATPB0101", "ATSS",
        "STPX", "STI", "VTVER",                              // non-ELM extensions
    ]

    @Test func configurationRawCANAndBusCommandsAreRefused() {
        for c in Self.dangerousATCommands {
            #expect(!CommandSafetyPolicy.evaluateTransmission(c).isAllowed, "\(c)")
            #expect(!CommandSafetyPolicy.evaluateConsoleCommand(c).isAllowed, "\(c)")
        }
    }

    /// The complete set of AT commands that can ever be transmitted.
    @Test func transmittableAdapterCommandsAreExactlyTheDocumentedSet() {
        let expected: Set<String> = [
            "Z", "E0", "L0", "S1", "H1", "SP0", "I", "@1", "RV", "DP", "DPN", "CS", "IGN",
            "SH7E0", "SH7E1", "SH7E2", "SH7E3", "SH7E4", "SH7E5", "SH7E6", "SH7E7",
        ]
        #expect(CommandSafetyPolicy.transmittableATCommands == expected)
        #expect(CommandSafetyPolicy.consoleATCommands == ["I", "@1", "RV", "DP", "DPN", "CS", "IGN"])
    }

    // MARK: Injection and parsing

    @Test func injectionAndLookalikeInputsAreRefused() {
        let hostile = [
            "010C\r04", "010C\n04", "010C\r\n04", "0100\u{2028}04",   // line breaks → second command
            "010C\u{0}04", "04\u{0}", "AT\u{200B}PP0CSV23",             // NUL / zero-width
            "０１０Ｃ", "０４",                                          // full-width digits
            "ATıGN", "ATRV\u{0131}", "01ﬀ", "ATSP0ß", "010C\t",       // non-ASCII that uppercases to ASCII; tab
            "01" + String(repeating: "00", count: 7),                  // 8 bytes > one CAN frame
            "010C0", "0", "0G", "0x04",                                // malformed / count digit 0
            "AT", "AT ", "A T P P", "", " ",
        ]
        for input in hostile {
            #expect(!CommandSafetyPolicy.evaluateTransmission(input).isAllowed, "\(input.debugDescription)")
            #expect(!CommandSafetyPolicy.evaluateConsoleCommand(input).isAllowed, "\(input.debugDescription)")
        }
    }

    @Test func odd_length_suffix_never_changes_the_service() {
        // "0" + "4" would read as service 04 if the suffix were mis-parsed.
        #expect(CommandSafetyPolicy.obdService(of: "041") == 0x04)
        #expect(!CommandSafetyPolicy.evaluateTransmission("041").isAllowed)
    }

    // MARK: Truncation (a busy or waking adapter may lose leading characters)

    /// The auditor's examples: requests whose remainder, after the adapter
    /// lost their first character(s), would change vehicle state.
    @Test func linesThatTruncateIntoStateChangingRequestsAreRefused() {
        let cases: [(String, String)] = [
            ("0104", "→ 04 clear DTCs"), ("01041", "→ 041 clear DTCs"),
            ("010C1", "→ 10C1 diagnostic session"), ("01101", "→ 1101 ECU hard reset"),
            ("014FFFFFF", "→ 14FFFFFF clear diagnostic information"),
            ("020C00", "→ 20C0 service 20 with parameters"),
            ("01020304050607", "→ 1020… service 10 with parameters"),
            ("0904", "→ 04"), ("0A04", "→ 04"), ("0304", "→ 04"),
        ]
        for (c, why) in cases {
            #expect(CommandSafetyPolicy.dangerousTruncation(of: c) != nil, "\(c) \(why)")
            #expect(!CommandSafetyPolicy.evaluateTransmission(c).isAllowed, "\(c) \(why)")
            #expect(!CommandSafetyPolicy.evaluateConsoleCommand(c).isAllowed, "\(c) \(why)")
        }
    }

    /// Exhaustive: no allowed line, truncated by any number of leading
    /// characters, is a service 04 request or a non-read request with
    /// parameters.
    @Test func noTransmittableLineTruncatesIntoAStateChangingRequest() {
        var lines = CommandSafetyPolicy.transmittableATCommands.map { "AT" + $0 }
        for service in CommandSafetyPolicy.readOnlyServices {
            for b in 0...0xFF {
                lines.append(Hex.byteString(service) + Hex.byteString(UInt8(b)))
                lines.append(Hex.byteString(service) + Hex.byteString(UInt8(b)) + "1")
            }
            lines.append(Hex.byteString(service))
        }
        var allowedCount = 0
        for line in lines where CommandSafetyPolicy.evaluateTransmission(line).isAllowed {
            allowedCount += 1
            let chars = Array(line)
            for drop in 1..<max(1, chars.count) {
                let tail = String(chars[drop...])
                guard tail.allSatisfy(Hex.isHexDigit) else { continue }
                let even = tail.count % 2 == 0 ? tail : String(tail.dropLast())
                guard let bytes = Hex.bytes(even), let service = bytes.first else { continue }
                #expect(service != 0x04, "\(line) truncates to \(tail)")
                #expect(CommandSafetyPolicy.readOnlyServices.contains(service) || bytes.count == 1,
                        "\(line) truncates to \(tail)")
            }
        }
        #expect(allowedCount > 1_000)
    }

    @Test func theResyncProbeIsTransmittableAndHarmlessWhenTruncated() {
        let probe = ELM327Session.resyncProbe
        #expect(probe == "ATI")
        #expect(CommandSafetyPolicy.evaluateTransmission(probe).isAllowed)
        // Its truncations are not hex, so not requests: "TI", "I".
        #expect(Array(probe).indices.dropFirst().allSatisfy { i in
            !String(Array(probe)[i...]).allSatisfy(Hex.isHexDigit)
        })
        // A partial line left in the adapter followed by the probe isn't hex.
        for partial in ["0", "01", "010", "AT", "ATS", "ATSP"] {
            #expect(!(partial + probe).allSatisfy(Hex.isHexDigit))
        }
    }

    // MARK: Session gate (structural enforcement for every caller)

    @Test func sessionRefusesAndWritesNothing() async throws {
        let t = ScriptedTransport { _ in .text("OK\r\r>", after: .milliseconds(1)) }
        let session = ELM327Session(transport: t, log: CommLog())
        await session.start(consuming: try await t.open(log: session.log))
        let refused = Self.dangerousRequests.map(\.0) + Self.dangerousATCommands + ["010C\r04", "010C\u{0}04"]
        for c in refused {
            do {
                _ = try await session.execute(c)
                Issue.record("\(c.debugDescription) was transmitted")
            } catch ELMSessionError.commandRefused {
                // expected
            } catch {
                Issue.record("\(c.debugDescription): unexpected error \(error)")
            }
        }
        #expect(t.writtenCommands.isEmpty, "bytes reached the transport: \(t.writtenCommands)")
        #expect(session.log.exportText().contains("REFUSED by read-only policy"))
    }

    @Test func sessionTransmitsExactlyTheEvaluatedText() async throws {
        let t = ScriptedTransport { _ in .text("41 0C 1A F8\r\r>", after: .milliseconds(1)) }
        let session = ELM327Session(transport: t, log: CommLog())
        await session.start(consuming: try await t.open(log: session.log))
        _ = try await session.execute(" 01 0c ")
        #expect(t.writtenCommands == ["010C"])
    }

    /// Every command string the code itself can produce passes the gate,
    /// except the ones the truncation rule deliberately blocks (PID 04 and
    /// every response-count-hinted request), which the code never sends.
    @Test func everyBuiltInCommandIsTransmittable() {
        var commands = ELMInitializer.adapterSteps.map(\.command)
        commands += ["ATDPN", "ATDP", "ATSP0", "0100", "ATI", ELM327Session.resyncProbe] // init, discovery, BLE probe, resync
        commands += stride(from: 0x20, through: 0xE0, by: 0x20).map { "01" + Hex.byteString(UInt8($0)) }
        commands += (0x7E8...0x7EF).compactMap { ECUAddress.can11(UInt32($0)).physicalRequestID }
            .map { "ATSH" + String($0, radix: 16, uppercase: true) }
        for c in commands {
            #expect(CommandSafetyPolicy.evaluateTransmission(c).isAllowed, "\(c)")
        }
        let blocked = StandardPIDs.all.map(\.key.requestCommand)
            .filter { !CommandSafetyPolicy.evaluateTransmission($0).isAllowed }
        #expect(blocked == ["0104"])
        #expect(StandardPIDs.all.allSatisfy { !CommandSafetyPolicy.evaluateTransmission($0.key.requestCommand + "1").isAllowed })
        #expect(StandardPIDs.all.allSatisfy { $0.mode == 0x01 })
        #expect(PollingPreset.allCases.allSatisfy { !$0.channels.contains(.engineLoad) })
    }

    /// The session never sends a bare CR (an idle ELM327 repeats its last
    /// command on one). After a lost prompt — here the persistent `AT SP 0` —
    /// it probes with `ATI` and only then sends the next command.
    @Test func resyncNeverRepeatsACommandAndNeverSendsABareCR() async throws {
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "ATSP0": return .silence
            case "ATI": return .text("ELM327 v1.5\r\r>", after: .milliseconds(5))
            default: return .text("OK\r\r>", after: .milliseconds(5))
            }
        }
        var timing = ELM327Session.Timing()
        timing.defaultTimeout = .milliseconds(200)
        timing.latePromptGrace = .milliseconds(100)
        timing.resyncTimeout = .milliseconds(200)
        let s = ELM327Session(transport: t, log: CommLog(), timing: timing)
        await s.start(consuming: try await t.open(log: s.log))
        _ = try await s.execute("ATE0")
        await #expect(throws: ELMSessionError.timedOut(command: "ATSP0")) { try await s.execute("ATSP0") }
        let ex = try await s.execute("ATRV")
        #expect(ex.response.lines == ["OK"])
        #expect(t.writtenCommands == ["ATE0", "ATSP0", "ATI", "ATRV"])
        #expect(!t.writtenCommands.contains(""))
    }
}

// MARK: - End-to-end outbound capture

@MainActor
@Suite("Read-only safety: end-to-end outbound capture")
struct OutboundCaptureTests {
    /// Runs the real engine (all presets, both experimental options, the
    /// console with hostile input) against the emulated adapter and checks
    /// every byte sequence the adapter received.
    @Test func everythingTheAdapterReceivesIsAllowed() async throws {
        let sim = SimulatedELM327Transport()
        let engine = TelemetryEngine(options: ELMOptions(physicalAddressing: true, responseCountHint: true),
                                     pollingPreset: .rpmOnly)
        engine.start(transport: sim)
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        for preset in PollingPreset.allCases {
            engine.pollingPreset = preset
            try await Task.sleep(for: .milliseconds(400))
        }
        let consoleInputs = ReadOnlySafetyTests.dangerousRequests.map(\.0)
            + ReadOnlySafetyTests.dangerousATCommands + ["010C\r04", "ATZ", "ATSP6", "0105", "03", "0902", "ATRV"]
        engine.pollingPreset = .rpmOnly
        // The preset change is applied asynchronously and one request from
        // the previous set may already be in flight: wait for both.
        try await waitUntil(seconds: 5) { engine.polledChannels == [.engineRPM] }
        try await Task.sleep(for: .milliseconds(300))
        let beforeConsole = sim.commandsReceived.count
        for input in consoleInputs { _ = await engine.sendConsoleCommand(input) }
        let consolePhase = Array(sim.commandsReceived.dropFirst(beforeConsole)).filter { $0 != "010C" && $0 != "010C1" }
        await engine.stop()

        let received = sim.commandsReceived
        #expect(!received.isEmpty)
        for command in received where !command.isEmpty {
            #expect(CommandSafetyPolicy.evaluateTransmission(command).isAllowed, "adapter received \(command)")
        }
        // During the console phase only the allowed console inputs (plus RPM
        // polling, filtered out above) reached the adapter, in order.
        let allowedConsole = consoleInputs.filter { CommandSafetyPolicy.evaluateConsoleCommand($0).isAllowed }
        #expect(allowedConsole == ["0105", "03", "0902", "ATRV"])
        #expect(consolePhase == allowedConsole.map(CommandSafetyPolicy.normalize), "console traffic: \(consolePhase)")
        // Automatic traffic is service 01 plus the documented AT set only.
        let automaticAT = Set(received.filter { $0.hasPrefix("AT") })
        #expect(automaticAT.isSubset(of: ["ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATI", "AT@1", "ATRV",
                                          "ATDPN", "ATDP", "ATSH7E0"]))
        // The emulated adapter was already automatic: no persistent adapter write.
        #expect(!received.contains("ATSP0"))
        #expect(sim.currentStoredProtocol == "0")
        #expect(!received.contains("")) // no bare-CR resync was needed
    }

    @Test func protocolIsStoredOnlyWhenAdapterIsNotAlreadyAutomatic() async throws {
        var config = SimulatedELM327Transport.Configuration()
        config.initialStoredProtocol = "6" // e.g. left fixed by another app
        let sim = SimulatedELM327Transport(configuration: config)
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: sim)
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        #expect(engine.adapterInfo?.storedProtocolBeforeInit == "6")
        #expect(engine.adapterInfo?.persistentAdapterWrites == ["ATSP0"])
        #expect(sim.commandsReceived.filter { $0 == "ATSP0" }.count == 1)
        #expect(engine.debugReport(appVersion: "t").contains("Persistent adapter settings changed this session: ATSP0"))
        await engine.stop()
    }
}

// MARK: - Bluetooth write gating

@Suite("Read-only safety: BLE probe gating")
struct BLEProbeGatingTests {
    let vendorConfig = GATTCharacteristicInfo(serviceUUID: "0000AB00-0000-1000-8000-00805F9B34FB",
                                              uuid: "0000AB01-0000-1000-8000-00805F9B34FB",
                                              properties: [.notify, .write])
    let knownNotify = GATTCharacteristicInfo(serviceUUID: "FFF0", uuid: "FFF1", properties: [.notify])
    let knownWrite = GATTCharacteristicInfo(serviceUUID: "FFF0", uuid: "FFF2", properties: [.write, .writeWithoutResponse])

    @Test func unknownCharacteristicsAreNeverProbed() {
        let onlyUnknown = GATTCandidateRanker.probeCandidates(from: [vendorConfig])
        #expect(onlyUnknown.isEmpty) // → open() throws .unrecognizedAdapterLayout, nothing written
        let mixed = GATTCandidateRanker.probeCandidates(from: [vendorConfig, knownNotify, knownWrite])
        #expect(mixed.map(\.serviceUUID) == ["FFF0"])
    }

    @Test func previouslyVerifiedPairIsTheOnlyExceptionAndMustExistOnTheAdapter() {
        let verified = GATTLinkCandidate(serviceUUID: vendorConfig.serviceUUID, writeUUID: vendorConfig.uuid,
                                         notifyUUID: vendorConfig.uuid, writeType: .withResponse)
        #expect(GATTCandidateRanker.probeCandidates(from: [vendorConfig], preferred: verified).count == 1)
        // A remembered pair that the connected adapter doesn't have is ignored.
        #expect(GATTCandidateRanker.probeCandidates(from: [knownNotify, knownWrite], preferred: verified)
            .allSatisfy { $0.serviceUUID == "FFF0" })
    }

    @Test func standardServicesAreNeverCandidates() {
        let deviceName = GATTCharacteristicInfo(serviceUUID: "1800", uuid: "2A00", properties: [.read, .write, .notify])
        #expect(GATTCandidateRanker.candidates(from: [deviceName]).isEmpty)
    }
}

// MARK: - Static outbound-surface inventory

/// Scans the source tree so that any NEW way of putting bytes on the wire
/// fails CI until it is reviewed against docs/SAFETY.md.
@Suite("Read-only safety: outbound surface inventory")
struct OutboundSurfaceInventoryTests {
    static var redlineRoot: URL {
        // …/Redline/Packages/RedlineCore/Tests/RedlineCoreTests/ThisFile.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    struct Source {
        let path: String
        let text: String
    }

    static func productionSources() throws -> [Source] {
        let roots = ["App", "Packages/RedlineCore/Sources"].map { redlineRoot.appendingPathComponent($0) }
        var result: [Source] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = url.path.replacingOccurrences(of: redlineRoot.path + "/", with: "")
                result.append(Source(path: relative, text: try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return result
    }

    static func count(_ pattern: String, in text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func sites(_ pattern: String, in sources: [Source]) -> [String: Int] {
        var map: [String: Int] = [:]
        for s in sources {
            let n = count(pattern, in: s.text)
            if n > 0 { map[(s.path as NSString).lastPathComponent] = n }
        }
        return map
    }

    @Test func outboundCallSitesMatchTheReviewedInventory() throws {
        let appDir = Self.redlineRoot.appendingPathComponent("App").path
        try #require(FileManager.default.fileExists(atPath: appDir),
                     "Run from a full checkout: the App sources must be present for this audit")
        let sources = try Self.productionSources()
        let message = "Outbound call sites changed — review the new path against docs/SAFETY.md, then update this inventory"

        // Bytes to the adapter leave the ELM layer at exactly one place: the
        // session's gated `transmit` (commands and the ATI resync probe).
        #expect(Self.sites(#"transport\??\.write\("#, in: sources) == ["ELM327Session.swift": 1], "\(message)")
        // GATT writes (BLE / Vgate): probe + write pump (2) and the CCCD.
        #expect(Self.sites(#"\.writeValue\("#, in: sources) == ["BLEOBDTransport.swift": 3], "\(message)")
        #expect(Self.sites(#"\.setNotifyValue\("#, in: sources) == ["BLEOBDTransport.swift": 1], "\(message)")
        #expect(Self.sites(#"\.writeValue\(\s*Data\("#, in: sources) == ["BLEOBDTransport.swift": 1], "\(message)")
        // Stream writes (External Accessory / MX+): only the pump writes to
        // an OutputStream, only the stream transport feeds the pump, and
        // only one place opens an EASession.
        #expect(Self.sites(#"\.write\([^)]*maxLength:"#, in: sources) == ["StreamPump.swift": 1], "\(message)")
        #expect(Self.sites(#"pump\.send\("#, in: sources) == ["AccessoryStreamTransport.swift": 1], "\(message)")
        #expect(Self.sites(#"EASession\("#, in: sources) == ["ExternalAccessoryCenter.swift": 1], "\(message)")
        // Every command goes through ELM327Session.execute (which enforces the policy).
        #expect(Self.sites(#"\.execute\("#, in: sources) == [
            "ELMInitializer.swift": 1, "PollingWorker.swift": 1, "TelemetryEngine.swift": 1,
        ], "\(message)")
        // The transports, accessory sessions and connectors that exist.
        let conformer = #"(class|actor|struct|enum|extension)\s+\w+[^{]*:[^{]*\b%@\b"#
        #expect(Self.sites(String(format: conformer, "OBDTransport"), in: sources) == [
            "BLEOBDTransport.swift": 1, "SimulatedELM327Transport.swift": 1, "AccessoryStreamTransport.swift": 1,
        ], "\(message)")
        #expect(Self.sites(String(format: conformer, "AccessoryStreamSession"), in: sources) == ["EAStreamSession.swift": 1],
                "\(message)")
        #expect(Self.sites(String(format: conformer, "AccessoryStreamConnector"), in: sources) == ["ExternalAccessoryCenter.swift": 1],
                "\(message)")
    }

    /// Every adapter/OBD-looking string literal in production code (outside
    /// comments) passes the transmission gate. The only reviewed exceptions
    /// are the 16-bit GATT UUIDs the BLE ranker recognizes. The simulator
    /// (which parses commands) and the policy itself are excluded.
    @Test func everyCommandLiteralInSourceIsAllowed() throws {
        let sources = try Self.productionSources().filter {
            !$0.path.contains("/Simulation/") && !$0.path.hasSuffix("CommandSafetyPolicy.swift")
        }
        let regex = try NSRegularExpression(pattern: #""((?:[Aa][Tt][A-Za-z0-9@]+)|(?:[0-9A-Fa-f]{2,14}))(?:\\r)?""#)
        var found: [String] = []
        for s in sources {
            for line in s.text.split(separator: "\n") {
                let code = String(line)
                if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for m in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                    guard let r = Range(m.range(at: 1), in: code) else { continue }
                    let literal = String(code[r])
                    if s.path.hasSuffix("GATTCandidateRanker.swift"), literal.count == 4 { continue } // GATT UUIDs
                    found.append(literal)
                }
            }
        }
        #expect(found.contains("ATZ") && found.contains("0100") && found.contains("ATI"))
        for command in found {
            #expect(CommandSafetyPolicy.evaluateTransmission(command).isAllowed, "literal \(command)")
        }
    }
}
