import Foundation
import CoreLocation

struct Vehicle: Codable, Equatable {
    var name = "Lada Largus"
    var year = 2024
    var engine = "1.6 MT"
    var powerHP = 106
    var seats = 7
    var fuel = "АИ-95"
    var mileage = 0
    var averageConsumption = 8.8
    var tankCapacityLiters = 50.0
    var plate = ""
    var vin = ""

    private enum CodingKeys: String, CodingKey {
        case name, year, engine, powerHP, seats, fuel
        case mileage, averageConsumption, tankCapacityLiters, plate, vin
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Lada Largus"
        year = try values.decodeIfPresent(Int.self, forKey: .year) ?? 2024
        engine = try values.decodeIfPresent(String.self, forKey: .engine) ?? "1.6 MT"
        powerHP = try values.decodeIfPresent(Int.self, forKey: .powerHP) ?? 106
        seats = try values.decodeIfPresent(Int.self, forKey: .seats) ?? 7
        fuel = try values.decodeIfPresent(String.self, forKey: .fuel) ?? "АИ-95"
        mileage = try values.decodeIfPresent(Int.self, forKey: .mileage) ?? 0
        averageConsumption = try values.decodeIfPresent(Double.self, forKey: .averageConsumption) ?? 8.8
        tankCapacityLiters = try values.decodeIfPresent(Double.self, forKey: .tankCapacityLiters) ?? 50.0
        plate = try values.decodeIfPresent(String.self, forKey: .plate) ?? ""
        vin = try values.decodeIfPresent(String.self, forKey: .vin) ?? ""
    }
}

struct FuelPlanningSettings: Codable, Equatable {
    var minimumReserveLiters = 10.0
    var startFuelPercent = 100.0
    var preferredNetworks: Set<String> = ["Лукойл", "Газпромнефть", "Роснефть"]
    var preferSameSide = true
    var maximumRecommendedStops = 8

    static let knownNetworks = [
        "Лукойл", "Газпромнефть", "Роснефть", "Татнефть", "Башнефть",
        "Teboil", "Нефтьмагистраль", "Трасса", "Газпром",
        "Сургутнефтегаз", "ПТК", "EKA", "Neste", "Ирбис",
        "Газойл", "Калина Ойл", "ВТК", "Движение"
    ]
}

struct ServiceRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var mileage = 0
    var title = ""
    var details = ""
    var cost = 0.0
}

struct ExpenseRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var category = "Топливо"
    var amount = 0.0
    var details = "АИ-95"
}

struct RoutePoint: Identifiable {
    let id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let kind: RoutePointKind

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum RoutePointKind: Equatable {
    case start, city, fuel, finish

    var symbol: String {
        switch self {
        case .start: "car.fill"
        case .city: "mappin.circle.fill"
        case .fuel: "fuelpump.fill"
        case .finish: "flag.checkered"
        }
    }
}

enum RoutingProvider: String, Codable, CaseIterable, Identifiable {
    case osm = "OpenStreetMap + OSRM"
    case apple = "Apple Maps"
    case yandex = "Яндекс"

    var id: String { rawValue }
}

struct RoutingSettings: Codable, Equatable {
    var provider: RoutingProvider = .osm
    var useTraffic = true
    var avoidTolls = false
    var avoidUnpaved = false
    var avoidPoorCondition = false
    var alternativeCount = 3
    var osrmBaseURL = "https://router.project-osrm.org"
    var diverseCorridors = true

    private enum CodingKeys: String, CodingKey {
        case provider, useTraffic, avoidTolls, avoidUnpaved, avoidPoorCondition, alternativeCount, osrmBaseURL, diverseCorridors
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(RoutingProvider.self, forKey: .provider) ?? .osm
        useTraffic = try c.decodeIfPresent(Bool.self, forKey: .useTraffic) ?? true
        avoidTolls = try c.decodeIfPresent(Bool.self, forKey: .avoidTolls) ?? false
        avoidUnpaved = try c.decodeIfPresent(Bool.self, forKey: .avoidUnpaved) ?? false
        avoidPoorCondition = try c.decodeIfPresent(Bool.self, forKey: .avoidPoorCondition) ?? false
        alternativeCount = min(3, max(1, try c.decodeIfPresent(Int.self, forKey: .alternativeCount) ?? 3))
        osrmBaseURL = try c.decodeIfPresent(String.self, forKey: .osrmBaseURL) ?? "https://router.project-osrm.org"
        diverseCorridors = try c.decodeIfPresent(Bool.self, forKey: .diverseCorridors) ?? true
    }
}

struct ChecklistItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var category: String
    var isRequired = true
    var isDone = false
}

struct SavedTrip: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "Новая поездка"
    var kind = "Путешествие"
    var start = "Москва, Байкальская улица, 17к1"
    var waypoints: [String] = []
    var finish = ""
    var departure = Date()
    var distanceKM = 0.0
    var durationSeconds = 0.0
    var fuelLiters = 0.0
    var fuelCost = 0.0
    var notes = ""
    var checklist: [ChecklistItem] = []
}


enum RoutePOICategory: String, Codable, CaseIterable, Hashable, Sendable {
    case fuel
    case hotel
    case food
    case grocery

    var title: String {
        switch self {
        case .fuel: "АЗС"
        case .hotel: "Отели"
        case .food: "Поесть"
        case .grocery: "Продукты"
        }
    }

    var symbol: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .hotel: "bed.double.fill"
        case .food: "fork.knife"
        case .grocery: "cart.fill"
        }
    }
}

enum RouteSide: String, Codable, Sendable {
    case left
    case right
    case onRoute
    case unknown

    var title: String {
        switch self {
        case .left: "слева"
        case .right: "справа"
        case .onRoute: "по ходу"
        case .unknown: "сторона неизвестна"
        }
    }
}

struct FuelSearchProgress: Equatable, Sendable {
    var checkedSections = 0
    var totalSections = 0
    var failedSections = 0

    var fraction: Double {
        guard totalSections > 0 else { return 0 }
        return min(1, Double(checkedSections) / Double(totalSections))
    }
}

struct RoutePOI: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let category: RoutePOICategory
    let distanceFromRouteKM: Double
    let estimatedDetourMinutes: Int

    // Road chainage from the nearest real OSM highway=milestone.
    // Nil means OSM has no usable milestone data near this POI.
    let roadKilometer: Double?
    let roadReference: String?
    let routeProgressKM: Double?
    let routeSide: RouteSide

    init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        category: RoutePOICategory,
        distanceFromRouteKM: Double,
        estimatedDetourMinutes: Int,
        roadKilometer: Double? = nil,
        roadReference: String? = nil,
        routeProgressKM: Double? = nil,
        routeSide: RouteSide = .unknown
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.distanceFromRouteKM = distanceFromRouteKM
        self.estimatedDetourMinutes = estimatedDetourMinutes
        self.roadKilometer = roadKilometer
        self.roadReference = roadReference
        self.routeProgressKM = routeProgressKM
        self.routeSide = routeSide
    }

    var roadKilometerLabel: String? {
        guard let roadKilometer else { return nil }
        let km = roadKilometer.rounded()
        if let roadReference, !roadReference.isEmpty {
            return "\(roadReference), ~\(Int(km)) км"
        }
        return "~\(Int(km)) км трассы"
    }
}

struct WeatherSummary: Equatable {
    var place: String
    var temperature: Double
    var windSpeed: Double
    var code: Int

    var description: String {
        switch code {
        case 0: "Ясно"
        case 1, 2, 3: "Переменная облачность"
        case 45, 48: "Туман"
        case 51...67: "Дождь"
        case 71...77: "Снег"
        case 80...82: "Ливни"
        case 95...99: "Гроза"
        default: "Погода"
        }
    }
}
