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
    var rememberedAdapterID: UUID?
    var rememberedAdapterName: String?
    /// GATT pair that answered the ELM probe last time (tried first).
    var verifiedLink: GATTLinkCandidate?
    var autoConnect = true
    var keepScreenAwake = true
    var elmOptions = ELMOptions()
    var pollingPreset: PollingPreset = .rpmAndBoost
    var simulationScenario: SimulationScenario = .autoCycle
    var showAllBluetoothDevices = false

    private static let key = "redline.settings.v1"

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
