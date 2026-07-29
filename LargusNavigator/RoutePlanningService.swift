import Foundation
import MapKit
import CoreLocation

struct PlannedRoute: Identifiable {
    let id = UUID()
    let orderedAddresses: [String]
    let mapItems: [MKMapItem]
    let routes: [MKRoute]
    let pathCoordinates: [[CLLocationCoordinate2D]]
    let distanceKM: Double
    let duration: TimeInterval
    let alternativeIndex: Int
    let provider: RoutingProvider
    let hasTolls: Bool

    var coordinates: [CLLocationCoordinate2D] {
        if !pathCoordinates.isEmpty { return pathCoordinates.flatMap { $0 } }
        return routes.flatMap { route in
            let points = route.polyline.points()
            return (0..<route.polyline.pointCount).map { points[$0].coordinate }
        }
    }

    var label: String {
        alternativeIndex == 0 ? "Оптимальный" : "Альтернатива \(alternativeIndex)"
    }
}

@MainActor
final class RoutePlanningService {
    func planAlternatives(
        start: String,
        waypoints: [String],
        finish: String,
        optimize: Bool,
        settings: RoutingSettings = RoutingSettings(),
        departure: Date = Date()
    ) async throws -> [PlannedRoute] {
        switch settings.provider {
        case .osm:
            return try await planOSM(start: start, waypoints: waypoints, finish: finish, optimize: optimize, settings: settings)
        case .yandex:
            let key = KeychainStore.yandexAPIKey()
            guard !key.isEmpty else { throw RouteError.yandexKeyMissing }
            return try await planYandex(
                start: start,
                waypoints: waypoints,
                finish: finish,
                optimize: optimize,
                settings: settings,
                departure: departure,
                apiKey: key
            )
        case .apple:
            return try await planApple(start: start, waypoints: waypoints, finish: finish, optimize: optimize, departure: departure)
        }
    }

    func plan(
        start: String,
        waypoints: [String],
        finish: String,
        optimize: Bool,
        settings: RoutingSettings = RoutingSettings(),
        departure: Date = Date()
    ) async throws -> PlannedRoute {
        guard let first = try await planAlternatives(
            start: start,
            waypoints: waypoints,
            finish: finish,
            optimize: optimize,
            settings: settings,
            departure: departure
        ).first else { throw RouteError.routeNotFound }
        return first
    }

    func testYandexKey(_ key: String) async throws -> String {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RouteError.yandexKeyMissing }
        _ = try await YandexJSRouteEngine.shared.calculate(
            addresses: ["Москва, Красная площадь", "Москва, Воробьёвы горы"],
            useTraffic: true,
            requestedResults: 1,
            apiKey: cleaned
        )
        return "JavaScript API и маршрутизация по адресам доступны"
    }

    func fuelStations(near route: PlannedRoute) async throws -> [MKMapItem] {
        let sampleItems = route.mapItems
        guard !sampleItems.isEmpty else { return [] }
        var found: [MKMapItem] = []
        let indices = Array(Set([0, max(0, sampleItems.count / 2), max(0, sampleItems.count - 1)])).sorted()
        for index in indices {
            let item = sampleItems[index]
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = "АЗС"
            request.region = MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 45_000, longitudinalMeters: 45_000)
            if let response = try? await MKLocalSearch(request: request).start() {
                for station in response.mapItems.prefix(5) {
                    if !found.contains(where: { existing in
                        let a = existing.placemark.coordinate
                        let b = station.placemark.coordinate
                        return abs(a.latitude - b.latitude) < 0.001 && abs(a.longitude - b.longitude) < 0.001
                    }) {
                        found.append(station)
                    }
                }
            }
        }
        return Array(found.prefix(12))
    }


    // MARK: - OpenStreetMap + OSRM

    private func planOSM(start: String, waypoints: [String], finish: String, optimize: Bool, settings: RoutingSettings) async throws -> [PlannedRoute] {
        let raw = [start] + waypoints.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } + [finish]
        var points = try await OSMRouteEngine.shared.geocode(raw)
        if optimize, points.count > 2 {
            points = try await OSMRouteEngine.shared.optimizedOrder(points, osrmBase: settings.osrmBaseURL)
        }

        let osmRoutes: [OSMRouteResult]
        if settings.diverseCorridors {
            osmRoutes = try await OSMRouteEngine.shared.threeDiverseRoutes(
                points: points,
                osrmBase: settings.osrmBaseURL,
                desiredCount: settings.alternativeCount
            )
        } else {
            osmRoutes = [try await OSMRouteEngine.shared.exactRoute(points: points, osrmBase: settings.osrmBaseURL)]
        }
        guard !osmRoutes.isEmpty else { throw RouteError.routeNotFound }

        return osmRoutes.enumerated().map { index, route in
            let mapItems: [MKMapItem] = route.coordinates.enumerated().map { i, coord in
                let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude))
                let item = MKMapItem(placemark: placemark)
                if i == 0 { item.name = "Старт" }
                else if i == route.coordinates.count - 1 { item.name = "Финиш" }
                else { item.name = i - 1 < route.corridorLabels.count ? route.corridorLabels[i - 1] : "Промежуточная точка" }
                return item
            }
            var labels = points.map(\.query)
            if !route.corridorLabels.isEmpty, labels.count >= 2 {
                labels.insert(contentsOf: route.corridorLabels.map { "Автокоридор: \($0)" }, at: max(1, labels.count / 2))
            }
            return PlannedRoute(
                orderedAddresses: labels,
                mapItems: mapItems,
                routes: [],
                pathCoordinates: [route.geometry.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }],
                distanceKM: route.distanceMeters / 1000,
                duration: route.durationSeconds,
                alternativeIndex: index,
                provider: .osm,
                hasTolls: false
            )
        }.sorted {
            if abs($0.duration - $1.duration) < 180 { return $0.distanceKM < $1.distanceKM }
            return $0.duration < $1.duration
        }
    }

    // MARK: - Apple Maps

    private func planApple(start: String, waypoints: [String], finish: String, optimize: Bool, departure: Date) async throws -> [PlannedRoute] {
        let raw = [start] + waypoints.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } + [finish]
        let items = try await appleGeocode(raw)
        let orderedItems: [MKMapItem]
        let orderedAddresses: [String]

        if optimize, items.count > 2 {
            let middle = Array(items.dropFirst().dropLast())
            let optimized = nearestNeighbor(from: items[0], points: middle)
            orderedItems = [items[0]] + optimized + [items[items.count - 1]]
            orderedAddresses = orderedItems.map { $0.name ?? $0.placemark.title ?? "Точка" }
        } else {
            orderedItems = items
            orderedAddresses = raw
        }

        var legAlternatives: [[MKRoute]] = []
        for index in 0..<(orderedItems.count - 1) {
            let request = MKDirections.Request()
            request.source = orderedItems[index]
            request.destination = orderedItems[index + 1]
            request.transportType = .automobile
            request.requestsAlternateRoutes = true
            request.departureDate = max(departure, Date())
            let response = try await MKDirections(request: request).calculate()
            guard !response.routes.isEmpty else { throw RouteError.routeNotFound }
            let sorted = response.routes.sorted {
                if abs($0.expectedTravelTime - $1.expectedTravelTime) < 60 { return $0.distance < $1.distance }
                return $0.expectedTravelTime < $1.expectedTravelTime
            }
            legAlternatives.append(Array(sorted.prefix(3)))
        }

        let maxOptions = min(3, legAlternatives.map(\.count).max() ?? 1)
        var result: [PlannedRoute] = []
        for optionIndex in 0..<maxOptions {
            let chosen = legAlternatives.map { routes in optionIndex < routes.count ? routes[optionIndex] : routes[0] }
            let paths = chosen.map { route -> [CLLocationCoordinate2D] in
                let points = route.polyline.points()
                return (0..<route.polyline.pointCount).map { points[$0].coordinate }
            }
            let planned = PlannedRoute(
                orderedAddresses: orderedAddresses,
                mapItems: orderedItems,
                routes: chosen,
                pathCoordinates: paths,
                distanceKM: chosen.reduce(0) { $0 + $1.distance } / 1000,
                duration: chosen.reduce(0) { $0 + $1.expectedTravelTime },
                alternativeIndex: optionIndex,
                provider: .apple,
                hasTolls: false
            )
            if !result.contains(where: { abs($0.distanceKM - planned.distanceKM) < 0.5 && abs($0.duration - planned.duration) < 120 }) {
                result.append(planned)
            }
        }
        return result.sorted { $0.duration < $1.duration }
    }

    private func appleGeocode(_ addresses: [String]) async throws -> [MKMapItem] {
        var result: [MKMapItem] = []
        for address in addresses {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = address
            request.resultTypes = .address
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { throw RouteError.addressNotFound(address) }
            result.append(item)
        }
        return result
    }

    private func nearestNeighbor(from start: MKMapItem, points: [MKMapItem]) -> [MKMapItem] {
        var remaining = points
        var current = start
        var ordered: [MKMapItem] = []
        while !remaining.isEmpty {
            let currentLocation = CLLocation(latitude: current.placemark.coordinate.latitude, longitude: current.placemark.coordinate.longitude)
            let nearestIndex = remaining.indices.min { a, b in
                let la = CLLocation(latitude: remaining[a].placemark.coordinate.latitude, longitude: remaining[a].placemark.coordinate.longitude)
                let lb = CLLocation(latitude: remaining[b].placemark.coordinate.latitude, longitude: remaining[b].placemark.coordinate.longitude)
                return currentLocation.distance(from: la) < currentLocation.distance(from: lb)
            }!
            current = remaining.remove(at: nearestIndex)
            ordered.append(current)
        }
        return ordered
    }

    // MARK: - Yandex JavaScript API

    private func planYandex(
        start: String,
        waypoints: [String],
        finish: String,
        optimize: Bool,
        settings: RoutingSettings,
        departure: Date,
        apiKey: String
    ) async throws -> [PlannedRoute] {
        var addresses = [start] + waypoints.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } + [finish]

        // JS API 2.1 умеет геокодировать адресные referencePoints самостоятельно.
        // Для оптимизации порядка используем Apple Local Search только как локальный вспомогательный
        // механизм; сами маршруты и адресное геокодирование выполняет Яндекс JS API.
        if optimize, addresses.count > 2 {
            let items = try await appleGeocode(addresses)
            let middle = Array(items.dropFirst().dropLast())
            let optimized = nearestNeighbor(from: items[0], points: middle)
            let orderedItems = [items[0]] + optimized + [items[items.count - 1]]
            addresses = orderedItems.map { $0.name ?? $0.placemark.title ?? "Точка" }
        }

        let jsRoutes = try await YandexJSRouteEngine.shared.calculate(
            addresses: addresses,
            useTraffic: settings.useTraffic,
            requestedResults: settings.alternativeCount,
            apiKey: apiKey
        )

        // Для подписей точек и поиска АЗС получаем координаты только после успешного маршрута.
        // Если Apple Search не найдёт адрес, маршрут Яндекса всё равно не теряем.
        let mapItems = (try? await appleGeocode(addresses)) ?? []

        return jsRoutes.prefix(3).enumerated().map { index, route in
            PlannedRoute(
                orderedAddresses: addresses,
                mapItems: mapItems,
                routes: [],
                pathCoordinates: route.coordinates,
                distanceKM: route.distanceMeters / 1000,
                duration: route.durationSeconds,
                alternativeIndex: index,
                provider: .yandex,
                hasTolls: false
            )
        }.sorted { $0.duration < $1.duration }
    }
}

enum RouteError: LocalizedError {
    case addressNotFound(String)
    case routeNotFound
    case yandexKeyMissing
    case invalidRequest
    case yandexResponse(String)

    var errorDescription: String? {
        switch self {
        case .addressNotFound(let address): "Не найден адрес: \(address)"
        case .routeNotFound: "Не удалось построить автомобильный маршрут"
        case .yandexKeyMissing: "В настройках не указан API-ключ Яндекс Карт"
        case .invalidRequest: "Не удалось сформировать запрос маршрута"
        case .yandexResponse(let text): text
        }
    }
}
