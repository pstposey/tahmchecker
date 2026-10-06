import Foundation
import Testing
@testable import RedlineCore

@Suite("ELM327 framing and responses")
struct ELMParsingTests {
    @Test func framerSplitsOnPromptAcrossChunks() {
        var f = ELMResponseFramer()
        #expect(f.append(Array("41 0C 1".utf8)).isEmpty)
        #expect(f.hasPartialResponse)
        let done = f.append(Array("A F8 \r\r>41 0D".utf8))
        #expect(done == ["41 0C 1A F8 \r\r"])
        #expect(f.append(Array(" 00\r\r>".utf8)) == ["41 0D 00\r\r"])
        #expect(!f.hasPartialResponse)
    }

    @Test func framerDropsNULAndBoundsMemory() {
        var f = ELMResponseFramer(maxBufferedBytes: 16)
        #expect(f.append([0x00, 0x4F, 0x4B, 0x00, 0x3E]) == ["OK"])
        _ = f.append([UInt8](repeating: 0x41, count: 100))
        #expect(f.overflowCount > 0)
        #expect(f.partialText.count <= 16)
    }

    @Test func removesEchoAndSearching() {
        let r = ELMResponse(raw: "0100\rSEARCHING...\r7E8 06 41 00 BE 3F A8 13 \r\r", command: "0100")
        #expect(r.echoed)
        #expect(r.searched)
        #expect(r.lines == ["7E8 06 41 00 BE 3F A8 13"])
        #expect(r.hexLines.count == 1)
    }

    @Test func classifiesMessages() {
        #expect(ELMResponse(raw: "NO DATA\r\r").messages == [.noData])
        #expect(ELMResponse(raw: "SEARCHING...\rUNABLE TO CONNECT\r\r").messages == [.unableToConnect])
        #expect(ELMResponse(raw: "?\r\r").isUnknownCommand)
        #expect(ELMResponse(raw: "CAN ERROR\r").messages == [.canError])
        #expect(ELMResponse(raw: "BUS INIT: ...ERROR\r").messages == [.busInitError])
        #expect(ELMResponse(raw: "BUS INIT: ...OK\r41 0C 1A F8\r").lines == ["41 0C 1A F8"])
        #expect(ELMResponse(raw: "STOPPED\r").messages == [.stopped])
        #expect(ELMResponse(raw: "41 0C 1A F8 <DATA ERROR\r").messages == [.dataError])
        #expect(ELMResponse(raw: "ERR94\r").messages == [.internalError])
        #expect(ELMResponse(raw: "LV RESET\r").messages == [.lowVoltageReset])
        #expect(ELMResponse(raw: "\r\rOK\r\r").isOK)
    }

    @Test func atzBannerWithEcho() {
        let r = ELMResponse(raw: "ATZ\r\r\rELM327 v2.3\r\r", command: "ATZ")
        #expect(r.firstTextLine == "ELM327 v2.3")
        #expect(ELMResponse.elmVersion(fromBanner: "ELM327 v2.3") == "2.3")
        #expect(ELMResponse.elmVersion(fromBanner: "ELM327 v1.4b") == "1.4b")
        #expect(ELMResponse.elmVersion(fromBanner: "OBDII to RS232 Interpreter") == nil)
    }

    @Test func dpnParsing() {
        #expect(OBDProtocol.parseDPN("A6")! == (OBDProtocol.iso_15765_4_can11_500, true))
        #expect(OBDProtocol.parseDPN("7")! == (OBDProtocol.iso_15765_4_can29_500, false))
        #expect(OBDProtocol.parseDPN("XYZ") == nil)
    }
}

@Suite("OBD frame parsing")
struct OBDFrameParserTests {
    @Test func singleFrameWithHeaders() {
        let p = OBDFrameParser.parse(lines: ["7E8 04 41 0C 1A F8"], headersOn: true, protocol: .iso_15765_4_can11_500)
        #expect(p.messages == [ECUMessage(ecu: .can11(0x7E8), payload: [0x41, 0x0C, 0x1A, 0xF8])])
        #expect(p.issues.isEmpty)
    }

    @Test func paddingAfterPCILengthIsIgnored() {
        let p = OBDFrameParser.parse(lines: ["7E8 03 41 0D 32 AA AA AA AA"], headersOn: true, protocol: nil)
        #expect(p.messages.first?.payload == [0x41, 0x0D, 0x32])
    }

    @Test func multipleECUs() {
        let lines = ["7E8 06 41 00 BE 3F A8 13", "7E9 06 41 00 80 00 00 00"]
        let p = OBDFrameParser.parse(lines: lines, headersOn: true, protocol: nil)
        #expect(p.messages.map(\.ecu) == [.can11(0x7E8), .can11(0x7E9)])
    }

    @Test func isoTPMultiFrameVIN() {
        // 49 02 01 + 17-char VIN = 20 bytes (0x14).
        let lines = [
            "7E8 10 14 49 02 01 31 47 31",
            "7E8 21 4A 43 35 34 34 34 52",
            "7E8 22 37 32 35 32 33 36 37",
        ]
        let p = OBDFrameParser.parse(lines: lines, headersOn: true, protocol: .iso_15765_4_can11_500)
        #expect(p.issues.isEmpty)
        let payload = p.messages.first!.payload
        #expect(payload.count == 20)
        #expect(String(decoding: payload.dropFirst(3), as: UTF8.self) == "1G1JC5444R7252367")
    }

    @Test func multiFrameSequenceErrorIsReportedNotCrashed() {
        let lines = ["7E8 10 14 49 02 01 31 47 31", "7E8 22 37 32 35 32 33 36 37"]
        let p = OBDFrameParser.parse(lines: lines, headersOn: true, protocol: nil)
        #expect(p.messages.isEmpty)
        #expect(!p.issues.isEmpty)
    }

    @Test func twentyNineBitHeaders() {
        let p = OBDFrameParser.parse(lines: ["18 DA F1 10 03 41 0D 32"], headersOn: true, protocol: .iso_15765_4_can29_500)
        #expect(p.messages == [ECUMessage(ecu: ECUAddress(value: 0x18DA_F110, kind: .can29), payload: [0x41, 0x0D, 0x32])])
        // Heuristic when protocol unknown.
        #expect(OBDFrameParser.parse(lines: ["18 DA F1 10 03 41 0D 32"], headersOn: true, protocol: nil).messages.count == 1)
    }

    @Test func spacesOffWithKnownProtocol() {
        let p = OBDFrameParser.parse(lines: ["7E804410C1AF8"], headersOn: true, protocol: .iso_15765_4_can11_500)
        #expect(p.messages.first?.payload == [0x41, 0x0C, 0x1A, 0xF8])
    }

    @Test func headersOff() {
        #expect(OBDFrameParser.parse(lines: ["41 0C 1A F8"], headersOn: false, protocol: nil).messages
            == [ECUMessage(ecu: nil, payload: [0x41, 0x0C, 0x1A, 0xF8])])
        let multi = ["014", "0: 49 02 01 31 47 31", "1: 4A 43 35 34 34 34 52", "2: 37 32 35 32 33 36 37"]
        let p = OBDFrameParser.parse(lines: multi, headersOn: false, protocol: nil)
        #expect(p.messages.count == 1)
        #expect(p.messages[0].payload.count == 20)
    }

    @Test func garbageIsAnIssueNotACrash() {
        let p = OBDFrameParser.parse(lines: ["7E8 0", "ZZZ 01", "7E8 07 41"], headersOn: true, protocol: nil)
        #expect(p.messages.isEmpty)
        #expect(p.issues.count == 3)
    }

    @Test func decoderPrefersEngineECUAndValidatesEcho() {
        let def = StandardPIDs.definition(for: .vehicleSpeed)!
        let response = ELMResponse(raw: "7E9 03 41 0D 10\r7E8 03 41 0D 32\r\r")
        let outcome = OBDResponseDecoder.decode(def, response: response, headersOn: true, protocol: nil,
                                                preferredECUs: [.can11(0x7E8)])
        #expect(outcome == .value(50, raw: [0x32], ecu: .can11(0x7E8), plausible: true))

        // A response for a different PID must not be decoded as this one.
        let wrong = ELMResponse(raw: "7E8 03 41 0B 32\r\r")
        if case .malformed = OBDResponseDecoder.decode(def, response: wrong, headersOn: true, protocol: nil) {} else {
            Issue.record("mismatched PID echo should be malformed")
        }
        let noData = OBDResponseDecoder.decode(def, response: ELMResponse(raw: "NO DATA\r\r"), headersOn: true, protocol: nil)
        #expect(noData == .message(.noData))
        let nrc = OBDResponseDecoder.decode(def, response: ELMResponse(raw: "7E8 03 7F 01 12\r\r"), headersOn: true, protocol: nil)
        #expect(nrc == .negativeResponse(nrc: 0x12, ecu: .can11(0x7E8)))
        let short = OBDResponseDecoder.decode(StandardPIDs.definition(for: .engineRPM)!,
                                              response: ELMResponse(raw: "7E8 03 41 0C 1A\r\r"), headersOn: true, protocol: nil)
        if case .malformed = short {} else { Issue.record("short RPM payload should be malformed") }
    }

    @Test func implausibleValueIsFlaggedNotClamped() {
        let def = StandardPIDs.definition(for: .engineRPM)!
        let r = ELMResponse(raw: "7E8 04 41 0C FF FF\r\r")
        #expect(OBDResponseDecoder.decode(def, response: r, headersOn: true, protocol: nil)
            == .value(16_383.75, raw: [0xFF, 0xFF], ecu: .can11(0x7E8), plausible: false))
    }
}

@Suite("Command safety")
struct CommandSafetyTests {
    @Test func consoleAllowsReadOnly() {
        #expect(CommandSafetyPolicy.evaluateConsoleCommand("01 0C") == .allowed)
        #expect(CommandSafetyPolicy.evaluateConsoleCommand("0902") == .allowed)
        #expect(CommandSafetyPolicy.evaluateConsoleCommand("03") == .allowed)
        #expect(CommandSafetyPolicy.evaluateConsoleCommand("at rv") == .allowed)
        #expect(CommandSafetyPolicy.evaluateConsoleCommand("ATDPN") == .allowed)
    }

    @Test func consoleBlocksWritesAndStateChanges() {
        for c in ["04", "1101", "2E F190 00", "2701", "3101FF00", "ATPP 0C SV 23", "ATBRD 23", "ATSP6", "ATH0", "ATZ", "ATMA", "", "XYZ"] {
            if case .allowed = CommandSafetyPolicy.evaluateConsoleCommand(c) {
                Issue.record("\(c) should be blocked")
            }
        }
    }

    @Test func repeatSafety() {
        #expect(CommandSafetyPolicy.isRepeatSafe("010C"))
        #expect(CommandSafetyPolicy.isRepeatSafe("010C1")) // with response-count digit
        #expect(CommandSafetyPolicy.isRepeatSafe("ATRV"))
        #expect(!CommandSafetyPolicy.isRepeatSafe("04"))
        #expect(!CommandSafetyPolicy.isRepeatSafe("ATPP0CSV23"))
        #expect(CommandSafetyPolicy.obdService(of: "010C1") == 0x01)
    }
}

@Suite("GATT candidate ranking")
struct GATTCandidateTests {
    let table: [GATTCharacteristicInfo] = [
        .init(serviceUUID: "180A", uuid: "2A29", properties: [.read]),
        .init(serviceUUID: "1800", uuid: "2A00", properties: [.read, .write]),
        .init(serviceUUID: "FFF0", uuid: "FFF1", properties: [.notify]),
        .init(serviceUUID: "FFF0", uuid: "FFF2", properties: [.write, .writeWithoutResponse]),
        .init(serviceUUID: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", uuid: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
              properties: [.notify, .write]),
    ]

    @Test func excludesStandardServicesAndRanksPairs() {
        let c = GATTCandidateRanker.candidates(from: table)
        #expect(!c.contains { $0.serviceUUID == "1800" || $0.serviceUUID == "180A" })
        #expect(c.first?.serviceUUID == "FFF0")
        #expect(c.first?.writeUUID == "FFF2")
        #expect(c.first?.notifyUUID == "FFF1")
        #expect(c.first?.writeType == .withoutResponse)
        // Single characteristic with both notify+write is also a candidate.
        #expect(c.contains { $0.writeUUID == $0.notifyUUID })
    }

    @Test func previouslyVerifiedPairWins() {
        let verified = GATTLinkCandidate(serviceUUID: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
                                         writeUUID: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
                                         notifyUUID: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F", writeType: .withResponse)
        let c = GATTCandidateRanker.candidates(from: table, preferred: verified)
        #expect(c.first?.matches(verified) == true)
    }
}
