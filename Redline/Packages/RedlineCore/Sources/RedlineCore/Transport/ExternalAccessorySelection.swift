import Foundation

/// A Sendable snapshot of an `EAAccessory` (External Accessory framework):
/// what iOS reports about a connected MFi accessory. Captured on the main
/// thread so it can cross into the transport and the debug report.
public struct AccessoryDescriptor: Sendable, Equatable, Codable, Identifiable {
    /// Changes every time the accessory connects; not a stable identity.
    public var connectionID: Int
    public var name: String
    public var manufacturer: String
    public var modelNumber: String
    public var serialNumber: String
    public var firmwareRevision: String
    public var hardwareRevision: String
    /// Every protocol the accessory advertises (not only Redline's).
    public var protocolStrings: [String]

    public var id: Int { connectionID }

    public init(connectionID: Int, name: String, manufacturer: String, modelNumber: String,
                serialNumber: String, firmwareRevision: String, hardwareRevision: String, protocolStrings: [String]) {
        self.connectionID = connectionID
        self.name = name
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
        self.protocolStrings = protocolStrings
    }

    public var displayName: String { name.isEmpty ? "Unnamed accessory" : name }

    /// Key/value lines for the debug console and report. The serial number
    /// identifies the adapter, not the vehicle or the user.
    public var detailItems: [TransportLinkDetails.Item] {
        [
            .init("Accessory name", name),
            .init("Manufacturer", manufacturer),
            .init("Model", modelNumber),
            .init("Serial number", serialNumber),
            .init("Firmware", firmwareRevision),
            .init("Hardware", hardwareRevision),
            .init("Connection ID", String(connectionID)),
            .init("Advertised protocols", protocolStrings.isEmpty ? "(none)" : protocolStrings.joined(separator: ", ")),
        ]
    }

    public var remembered: RememberedAccessory {
        RememberedAccessory(name: name, manufacturer: manufacturer, modelNumber: modelNumber, serialNumber: serialNumber)
    }
}

/// The parts of an accessory's identity that survive reconnection.
public struct RememberedAccessory: Sendable, Equatable, Codable {
    public var name: String
    public var manufacturer: String
    public var modelNumber: String
    public var serialNumber: String

    public init(name: String, manufacturer: String, modelNumber: String, serialNumber: String) {
        self.name = name
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
    }

    /// Serial number when the accessory reports one; otherwise name,
    /// manufacturer and model must all match.
    public func matches(_ accessory: AccessoryDescriptor) -> Bool {
        if !serialNumber.isEmpty || !accessory.serialNumber.isEmpty {
            return serialNumber == accessory.serialNumber
        }
        return name == accessory.name && manufacturer == accessory.manufacturer && modelNumber == accessory.modelNumber
    }
}

/// Which connected accessory the user wants.
public enum AccessoryTarget: Sendable, Equatable {
    /// One of the currently connected accessories (tapped in the list).
    case connection(Int)
    /// The adapter remembered from a previous session.
    case remembered(RememberedAccessory)
    /// Whichever connected accessory speaks a supported protocol.
    case any
}

/// Chooses the accessory and protocol for an External Accessory session.
///
/// `declaredProtocols` are the strings in the app's Info.plist
/// (`UISupportedExternalAccessoryProtocols`), in order of preference. iOS
/// only lets an app open a session for a protocol it declares, so a protocol
/// is usable only when the accessory advertises it AND the app declares it.
public enum AccessorySelector {
    public struct Choice: Sendable, Equatable {
        public let accessory: AccessoryDescriptor
        public let protocolString: String
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// No MFi accessory is connected to the iPhone at all.
        case noAccessoryConnected
        /// An accessory is connected but reports no protocols yet: iOS
        /// reports none until MFi authentication has finished.
        case accessoryNotReady
        /// Accessories are connected, but none advertises a protocol Redline
        /// declares (their protocols are included for the debug log).
        case noSupportedProtocol([AccessoryDescriptor])
        /// Supported accessories are connected, but not the requested one.
        case targetNotConnected
        /// The app declares no accessory protocols (Info.plist misconfigured).
        case noDeclaredProtocols

        public var description: String {
            switch self {
            case .noAccessoryConnected:
                return "No MFi accessory is connected to this iPhone. Pair the OBDLink MX+ in Settings › Bluetooth and check it shows as Connected"
            case .accessoryNotReady:
                return "The accessory is connected but iOS hasn't finished authenticating it yet"
            case .noSupportedProtocol(let found):
                let list = found.map { "\($0.displayName) [\($0.protocolStrings.joined(separator: ", "))]" }.joined(separator: "; ")
                return "Connected accessories don't offer a protocol Redline supports: \(list)"
            case .targetNotConnected:
                return "The remembered adapter isn't connected to this iPhone right now"
            case .noDeclaredProtocols:
                return "Redline declares no accessory protocols (Info.plist UISupportedExternalAccessoryProtocols)"
            }
        }
    }

    /// The first declared protocol the accessory advertises.
    public static func supportedProtocol(of accessory: AccessoryDescriptor, declared: [String]) -> String? {
        declared.first { accessory.protocolStrings.contains($0) }
    }

    public static func choose(target: AccessoryTarget, from accessories: [AccessoryDescriptor],
                              declared: [String]) -> Result<Choice, Failure> {
        guard !declared.isEmpty else { return .failure(.noDeclaredProtocols) }
        guard !accessories.isEmpty else { return .failure(.noAccessoryConnected) }
        let supported = accessories
            .sorted { $0.connectionID < $1.connectionID }
            .compactMap { a in supportedProtocol(of: a, declared: declared).map { Choice(accessory: a, protocolString: $0) } }
        guard !supported.isEmpty else {
            if accessories.contains(where: { $0.protocolStrings.isEmpty }) { return .failure(.accessoryNotReady) }
            return .failure(.noSupportedProtocol(accessories))
        }
        let match: Choice?
        switch target {
        case .connection(let id): match = supported.first { $0.accessory.connectionID == id }
        case .remembered(let r): match = supported.first { r.matches($0.accessory) }
        case .any: match = supported.first
        }
        return match.map { .success($0) } ?? .failure(.targetNotConnected)
    }
}
