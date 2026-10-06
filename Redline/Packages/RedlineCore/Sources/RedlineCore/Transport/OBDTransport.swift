import Foundation

/// What kind of link carries the ELM327 byte stream.
public enum TransportKind: String, Sendable, Codable {
    case bluetoothLE
    /// In-process simulated ELM327 + vehicle. Never real telemetry.
    case simulated

    public var isSimulation: Bool { self == .simulated }
}

public struct TransportIdentity: Sendable, Equatable {
    public var kind: TransportKind
    /// Human-readable name, e.g. the BLE advertised name.
    public var name: String
    /// Stable identifier (CBPeripheral.identifier for BLE).
    public var identifier: String

    public init(kind: TransportKind, name: String, identifier: String) {
        self.kind = kind
        self.name = name
        self.identifier = identifier
    }
}

/// Link-level details discovered while opening the transport, shown in the
/// debug console (e.g. which GATT characteristics were verified).
public struct TransportLinkDetails: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public let key: String
        public let value: String
        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }
}

public enum TransportEvent: Sendable {
    /// Bytes received from the adapter, timestamped as close to receipt as
    /// the platform allows (the CoreBluetooth callback for BLE).
    case received(Data, at: MonotonicInstant)
    /// The link closed. `nil` means an orderly close requested by us.
    case closed(TransportError?)
}

public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case notAuthorized
    case peripheralNotFound
    case connectFailed(String)
    case connectTimedOut
    case noCompatibleCharacteristics
    /// No recognized ELM327 BLE layout; nothing was written to the adapter.
    case unrecognizedAdapterLayout
    case disconnected(String?)
    case writeFailed(String)
    case notOpen

    public var description: String {
        switch self {
        case .unavailable(let why): return "Transport unavailable: \(why)"
        case .notAuthorized: return "Bluetooth permission not granted"
        case .peripheralNotFound: return "Adapter not found — scan again"
        case .connectFailed(let why): return "Connection failed: \(why)"
        case .connectTimedOut: return "Connection timed out"
        case .noCompatibleCharacteristics: return "No characteristic pair answered like an ELM327"
        case .unrecognizedAdapterLayout:
            return "Unrecognized adapter Bluetooth layout — nothing was written to it. Share the debug report (it contains the GATT table) so the layout can be verified"
        case .disconnected(let why): return "Disconnected\(why.map { ": \($0)" } ?? "")"
        case .writeFailed(let why): return "Write failed: \(why)"
        case .notOpen: return "Transport is not open"
        }
    }
}

/// A byte pipe to an ELM327-compatible interpreter.
///
/// The transport knows nothing about ELM327 commands or OBD; it only moves
/// bytes and reports link state. Command framing, timeouts and serialization
/// live in `ELM327Session`.
///
/// Contract:
/// - `open` establishes the link and returns a stream of events. The stream
///   finishes after a `.closed` event. Calling `open` again after a close
///   re-establishes the link (used for reconnection).
/// - `write` may be called only between a successful `open` and the close.
/// - Implementations must deliver received bytes in order.
public protocol OBDTransport: AnyObject, Sendable {
    var identity: TransportIdentity { get }
    func open(log: CommLog) async throws -> AsyncStream<TransportEvent>
    func write(_ data: Data) async throws
    func close() async
    /// Link details discovered during `open` (for the debug console).
    func linkDetails() async -> TransportLinkDetails
}
