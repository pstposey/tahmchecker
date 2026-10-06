import Foundation
import RedlineCore

enum DataSource: String, Codable, CaseIterable, Identifiable {
    case vehicle
    case simulation

    var id: String { rawValue }
    var title: String { self == .vehicle ? "Vehicle (OBD adapter)" : "Simulation" }
}

/// Everything Redline persists in V1. Stored locally in UserDefaults as one
/// JSON blob; no cloud, no account.
struct AppSettings: Codable, Equatable {
    var dataSource: DataSource = .vehicle
    var units: UnitPreferences = .personalDefault
    /// The adapter connected last: a BLE adapter (Vgate iCar Pro 2S) or an
    /// MFi accessory (OBDLink MX+).
    var rememberedAdapter: RememberedAdapter?
    var autoConnect = true
    var keepScreenAwake = true
    var elmOptions = ELMOptions()
    var pollingPreset: PollingPreset = .rpmAndBoost
    var simulationScenario: SimulationScenario = .autoCycle
    var showAllBluetoothDevices = false

    private static let key = "redline.settings.v1"

    init() {}

    /// Field by field, so one unreadable or missing value (e.g. after an
    /// update adds a field) never resets everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        dataSource = value(.dataSource, d.dataSource)
        units = value(.units, d.units)
        autoConnect = value(.autoConnect, d.autoConnect)
        keepScreenAwake = value(.keepScreenAwake, d.keepScreenAwake)
        elmOptions = value(.elmOptions, d.elmOptions)
        pollingPreset = value(.pollingPreset, d.pollingPreset)
        simulationScenario = value(.simulationScenario, d.simulationScenario)
        showAllBluetoothDevices = value(.showAllBluetoothDevices, d.showAllBluetoothDevices)
        if let remembered = try? c.decodeIfPresent(RememberedAdapter.self, forKey: .rememberedAdapter) {
            rememberedAdapter = remembered
        } else {
            // Settings saved before MX+ support (BLE adapter only).
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            rememberedAdapter = RememberedAdapter.migrating(
                legacyID: (try? legacy?.decodeIfPresent(UUID.self, forKey: .rememberedAdapterID)) ?? nil,
                legacyName: (try? legacy?.decodeIfPresent(String.self, forKey: .rememberedAdapterName)) ?? nil,
                legacyLink: (try? legacy?.decodeIfPresent(GATTLinkCandidate.self, forKey: .verifiedLink)) ?? nil)
        }
    }

    private enum LegacyKeys: String, CodingKey {
        case rememberedAdapterID, rememberedAdapterName, verifiedLink
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
