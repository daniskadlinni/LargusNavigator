import Foundation
import Observation
import MapKit

@Observable
final class AppStore {
    var vehicle = Vehicle()
    var services: [ServiceRecord] = []
    var expenses: [ExpenseRecord] = []
    var trips: [SavedTrip] = []
    var routingSettings = RoutingSettings()
    var fuelPlanningSettings = FuelPlanningSettings()

    // Текущий рассчитанный маршрут хранится только в памяти.
    var currentRouteOptions: [PlannedRoute] = []
    var selectedRouteIndex = 0
    var currentFuelStations: [MKMapItem] = []
    var currentPOIs: [RoutePOI] = []
    var recommendedFuelStops: [RecommendedFuelStop] = []
    var currentFuelGaps: [FuelCoverageGap] = []
    var selectedPOICategories: Set<RoutePOICategory> = [.fuel]

    private let fileURL: URL
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private let cloudDataKey = "LargusNavigator.snapshot.v1"

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let folder = support.appendingPathComponent(
            "LargusNavigator",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        fileURL = folder.appendingPathComponent("data.json")
        load()
        // 1.0 migration: OpenStreetMap + OSRM becomes the default for route planning.
        if routingSettings.provider == .yandex || routingSettings.provider == .apple {
            routingSettings.provider = .osm
            routingSettings.alternativeCount = 3
            routingSettings.diverseCorridors = true
            save()
        }
    }

    var totalExpenses: Double {
        expenses.reduce(0) { $0 + $1.amount }
    }

    var nextServiceMileage: Int {
        let interval = 15_000
        return max(interval, ((vehicle.mileage / interval) + 1) * interval)
    }

    func addService(_ record: ServiceRecord) {
        services.append(record)
        services.sort { $0.date > $1.date }
        vehicle.mileage = max(vehicle.mileage, record.mileage)
        save()
    }

    func deleteServices(at offsets: IndexSet) {
        services.remove(atOffsets: offsets)
        save()
    }

    func addExpense(_ record: ExpenseRecord) {
        expenses.append(record)
        expenses.sort { $0.date > $1.date }
        save()
    }

    func deleteExpenses(at offsets: IndexSet) {
        expenses.remove(atOffsets: offsets)
        save()
    }


    func saveTrip(_ trip: SavedTrip) {
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = trip
        } else {
            trips.insert(trip, at: 0)
        }
        save()
    }

    func deleteTrips(at offsets: IndexSet) {
        trips.remove(atOffsets: offsets)
        save()
    }

    func save() {
        createAutomaticBackupIfNeeded()
        let snapshot = Snapshot(
            vehicle: vehicle,
            services: services,
            expenses: expenses,
            trips: trips,
            routingSettings: routingSettings,
            fuelPlanningSettings: fuelPlanningSettings,
            savedAt: Date()
        )
        guard let data = try? JSONEncoder.appEncoder.encode(snapshot) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
        cloudStore.set(data, forKey: cloudDataKey)
        cloudStore.synchronize()
    }

    private func load() {
        cloudStore.synchronize()
        let localSnapshot = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder.appDecoder.decode(Snapshot.self, from: $0)
        }
        let cloudSnapshot = cloudStore.data(forKey: cloudDataKey).flatMap {
            try? JSONDecoder.appDecoder.decode(Snapshot.self, from: $0)
        }
        guard let snapshot = [localSnapshot, cloudSnapshot]
            .compactMap({ $0 })
            .max(by: { $0.savedAt < $1.savedAt })
        else { return }

        vehicle = snapshot.vehicle
        services = snapshot.services.sorted { $0.date > $1.date }
        expenses = snapshot.expenses.sorted { $0.date > $1.date }
        trips = snapshot.trips
        routingSettings = snapshot.routingSettings
        fuelPlanningSettings = snapshot.fuelPlanningSettings
    }

    private func createAutomaticBackupIfNeeded() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              !Calendar.current.isDateInToday(modified)
        else { return }

        let folder = fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let destination = folder.appendingPathComponent("data_\(formatter.string(from: modified)).json")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.copyItem(at: fileURL, to: destination)
        }

        let backups = ((try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in backups.dropFirst(10) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}

private struct Snapshot: Codable {
    let vehicle: Vehicle
    let services: [ServiceRecord]
    let expenses: [ExpenseRecord]
    let trips: [SavedTrip]
    let routingSettings: RoutingSettings
    let fuelPlanningSettings: FuelPlanningSettings
    let savedAt: Date

    private enum CodingKeys: String, CodingKey { case vehicle, services, expenses, trips, routingSettings, fuelPlanningSettings, savedAt }

    init(vehicle: Vehicle, services: [ServiceRecord], expenses: [ExpenseRecord], trips: [SavedTrip], routingSettings: RoutingSettings, fuelPlanningSettings: FuelPlanningSettings, savedAt: Date) {
        self.vehicle = vehicle
        self.services = services
        self.expenses = expenses
        self.trips = trips
        self.routingSettings = routingSettings
        self.fuelPlanningSettings = fuelPlanningSettings
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vehicle = try c.decode(Vehicle.self, forKey: .vehicle)
        services = try c.decodeIfPresent([ServiceRecord].self, forKey: .services) ?? []
        expenses = try c.decodeIfPresent([ExpenseRecord].self, forKey: .expenses) ?? []
        trips = try c.decodeIfPresent([SavedTrip].self, forKey: .trips) ?? []
        routingSettings = try c.decodeIfPresent(RoutingSettings.self, forKey: .routingSettings) ?? RoutingSettings()
        fuelPlanningSettings = try c.decodeIfPresent(FuelPlanningSettings.self, forKey: .fuelPlanningSettings) ?? FuelPlanningSettings()
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
    }
}

private extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
