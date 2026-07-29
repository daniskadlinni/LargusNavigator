import Foundation

struct OSMCoordinate: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct OSMGeocodedPoint: Sendable {
    let query: String
    let displayName: String
    let coordinate: OSMCoordinate
}

struct OSMRouteResult: Sendable {
    let distanceMeters: Double
    let durationSeconds: Double
    let geometry: [OSMCoordinate]
    let corridorLabels: [String]
    let coordinates: [OSMCoordinate]
}

actor OSMRouteEngine {
    static let shared = OSMRouteEngine()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    private let nominatimBase = URL(string: "https://nominatim.openstreetmap.org")!

    func geocode(_ addresses: [String]) async throws -> [OSMGeocodedPoint] {
        var result: [OSMGeocodedPoint] = []
        for (index, address) in addresses.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: .milliseconds(1050))
            }
            var parts = URLComponents(url: nominatimBase.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [
                URLQueryItem(name: "format", value: "jsonv2"),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "q", value: address)
            ]
            guard let url = parts.url else { throw OSMError.invalidRequest }
            var request = URLRequest(url: url)
            request.setValue("LargusNavigator/1.2 (personal macOS route planner)", forHTTPHeaderField: "User-Agent")
            request.setValue("ru", forHTTPHeaderField: "Accept-Language")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw OSMError.geocoderUnavailable
            }
            let decoded = try JSONDecoder().decode([NominatimSearchItem].self, from: data)
            guard let first = decoded.first,
                  let lat = Double(first.lat), let lon = Double(first.lon) else {
                throw OSMError.addressNotFound(address)
            }
            result.append(OSMGeocodedPoint(query: address, displayName: first.displayName, coordinate: .init(latitude: lat, longitude: lon)))
        }
        return result
    }

    func optimizedOrder(_ points: [OSMGeocodedPoint], osrmBase: String) async throws -> [OSMGeocodedPoint] {
        guard points.count > 2 else { return points }
        let coordinateString = points.map { "\($0.coordinate.longitude),\($0.coordinate.latitude)" }.joined(separator: ";")
        guard let base = URL(string: osrmBase.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw OSMError.invalidRequest }
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        guard let endpoint = URL(string: "\(root)/trip/v1/driving/\(coordinateString)") else { throw OSMError.invalidRequest }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "source", value: "first"),
            URLQueryItem(name: "destination", value: "last"),
            URLQueryItem(name: "roundtrip", value: "false"),
            URLQueryItem(name: "overview", value: "false")
        ]
        guard let url = parts.url else { throw OSMError.invalidRequest }
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(OSRMTripResponse.self, from: data)
        guard response.code == "Ok", response.waypoints.count == points.count else { return points }
        let pairs = response.waypoints.enumerated().compactMap { idx, wp -> (Int, OSMGeocodedPoint)? in
            guard let order = wp.waypointIndex else { return nil }
            return (order, points[idx])
        }
        guard pairs.count == points.count else { return points }
        return pairs.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    func exactRoute(points: [OSMGeocodedPoint], osrmBase: String) async throws -> OSMRouteResult {
        guard let first = try await route(points: points, osrmBase: osrmBase, alternatives: 1, corridorLabels: []).first else {
            throw OSMError.noRoute
        }
        return first
    }

    func threeDiverseRoutes(points: [OSMGeocodedPoint], osrmBase: String, desiredCount: Int = 3) async throws -> [OSMRouteResult] {
        guard points.count >= 2 else { throw OSMError.invalidRequest }
        var candidates: [OSMRouteResult] = []

        // 1) Native OSRM alternatives through all mandatory points.
        let native = try await route(points: points, osrmBase: osrmBase, alternatives: min(3, max(1, desiredCount)), corridorLabels: [])
        for route in native where isDiverse(route, from: candidates) { candidates.append(route) }

        // 2) If OSRM did not return three genuinely different corridors, force two
        // route-specific via points on opposite sides of the longest leg.
        if candidates.count < desiredCount {
            let longest = longestLeg(in: points)
            let offsets = [1.0, -1.0]
            for side in offsets where candidates.count < desiredCount {
                let synthetic = corridorPoint(a: points[longest].coordinate, b: points[longest + 1].coordinate, side: side)
                if let snapped = try? await nearest(synthetic, osrmBase: osrmBase) {
                    var routedPoints = points
                    let label = (try? await reverseName(snapped)) ?? (side > 0 ? "Северный/восточный коридор" : "Южный/западный коридор")
                    let via = OSMGeocodedPoint(query: label, displayName: label, coordinate: snapped)
                    routedPoints.insert(via, at: longest + 1)
                    if let forced = try? await route(points: routedPoints, osrmBase: osrmBase, alternatives: 1, corridorLabels: [label]).first,
                       isDiverse(forced, from: candidates) {
                        candidates.append(forced)
                    }
                }
            }
        }

        // Rank by travel time, then distance. The first route is the recommendation.
        return Array(candidates.sorted {
            if abs($0.durationSeconds - $1.durationSeconds) < 180 { return $0.distanceMeters < $1.distanceMeters }
            return $0.durationSeconds < $1.durationSeconds
        }.prefix(desiredCount))
    }

    private func route(points: [OSMGeocodedPoint], osrmBase: String, alternatives: Int, corridorLabels: [String]) async throws -> [OSMRouteResult] {
        let coordinateString = points.map { "\($0.coordinate.longitude),\($0.coordinate.latitude)" }.joined(separator: ";")
        guard let base = URL(string: osrmBase.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw OSMError.invalidRequest }
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        guard let endpoint = URL(string: "\(root)/route/v1/driving/\(coordinateString)") else { throw OSMError.invalidRequest }
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "alternatives", value: String(alternatives)),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "steps", value: "false")
        ]
        guard let url = parts.url else { throw OSMError.invalidRequest }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw OSMError.routerUnavailable }
        let decoded = try JSONDecoder().decode(OSRMRouteResponse.self, from: data)
        guard decoded.code == "Ok", !decoded.routes.isEmpty else { throw OSMError.noRoute }
        return decoded.routes.map { r in
            let coords = r.geometry.coordinates.map { pair in
                OSMCoordinate(latitude: pair.count > 1 ? pair[1] : 0, longitude: pair.first ?? 0)
            }
            return OSMRouteResult(distanceMeters: r.distance, durationSeconds: r.duration, geometry: coords, corridorLabels: corridorLabels, coordinates: points.map(\.coordinate))
        }
    }

    private func nearest(_ point: OSMCoordinate, osrmBase: String) async throws -> OSMCoordinate {
        guard let base = URL(string: osrmBase.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw OSMError.invalidRequest }
        let coord = "\(point.longitude),\(point.latitude)"
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        guard let url = URL(string: "\(root)/nearest/v1/driving/\(coord)") else { throw OSMError.invalidRequest }
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(OSRMNearestResponse.self, from: data)
        guard response.code == "Ok", let loc = response.waypoints.first?.location, loc.count >= 2 else { throw OSMError.noRoute }
        return OSMCoordinate(latitude: loc[1], longitude: loc[0])
    }

    private func reverseName(_ point: OSMCoordinate) async throws -> String {
        try? await Task.sleep(for: .milliseconds(1050))
        var parts = URLComponents(url: nominatimBase.appendingPathComponent("reverse"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "zoom", value: "10"),
            URLQueryItem(name: "lat", value: String(point.latitude)),
            URLQueryItem(name: "lon", value: String(point.longitude))
        ]
        guard let url = parts.url else { throw OSMError.invalidRequest }
        var request = URLRequest(url: url)
        request.setValue("LargusNavigator/1.2 (personal macOS route planner)", forHTTPHeaderField: "User-Agent")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await session.data(for: request)
        let item = try JSONDecoder().decode(NominatimReverseItem.self, from: data)
        return item.address.city ?? item.address.town ?? item.address.village ?? item.address.county ?? item.displayName
    }

    private func longestLeg(in points: [OSMGeocodedPoint]) -> Int {
        guard points.count > 2 else { return 0 }
        var best = 0
        var bestDistance = -Double.infinity
        for i in 0..<(points.count - 1) {
            let d = haversine(points[i].coordinate, points[i + 1].coordinate)
            if d > bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    private func corridorPoint(a: OSMCoordinate, b: OSMCoordinate, side: Double) -> OSMCoordinate {
        let midLat = (a.latitude + b.latitude) / 2
        let midLon = (a.longitude + b.longitude) / 2
        let distanceKM = haversine(a, b) / 1000
        let offsetKM = min(180, max(30, distanceKM * 0.12))
        let dx = (b.longitude - a.longitude) * cos(midLat * .pi / 180)
        let dy = b.latitude - a.latitude
        let length = max(0.000001, sqrt(dx * dx + dy * dy))
        let perpX = -dy / length * side
        let perpY = dx / length * side
        let latOffset = (offsetKM / 111.0) * perpY
        let lonOffset = (offsetKM / max(20.0, 111.0 * cos(midLat * .pi / 180))) * perpX
        return OSMCoordinate(latitude: midLat + latOffset, longitude: midLon + lonOffset)
    }

    private func haversine(_ a: OSMCoordinate, _ b: OSMCoordinate) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180
        let p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp/2) * sin(dp/2) + cos(p1) * cos(p2) * sin(dl/2) * sin(dl/2)
        return 2 * r * atan2(sqrt(h), sqrt(1-h))
    }

    private func isDiverse(_ candidate: OSMRouteResult, from existing: [OSMRouteResult]) -> Bool {
        for other in existing {
            let distanceDelta = abs(candidate.distanceMeters - other.distanceMeters)
            let durationDelta = abs(candidate.durationSeconds - other.durationSeconds)
            let geometryDelta = sampledGeometryDistance(candidate.geometry, other.geometry)
            if distanceDelta < 5_000 && durationDelta < 300 && geometryDelta < 15_000 { return false }
        }
        return true
    }

    private func sampledGeometryDistance(_ a: [OSMCoordinate], _ b: [OSMCoordinate]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return .infinity }
        let fractions = [0.25, 0.5, 0.75]
        return fractions.map { f in
            let ai = min(a.count - 1, Int(Double(a.count - 1) * f))
            let bi = min(b.count - 1, Int(Double(b.count - 1) * f))
            return haversine(a[ai], b[bi])
        }.reduce(0, +) / Double(fractions.count)
    }
}

private struct NominatimSearchItem: Decodable {
    let lat: String
    let lon: String
    let displayName: String
    enum CodingKeys: String, CodingKey { case lat, lon; case displayName = "display_name" }
}

private struct NominatimReverseItem: Decodable {
    let displayName: String
    let address: Address
    enum CodingKeys: String, CodingKey { case displayName = "display_name", address }
    struct Address: Decodable {
        let city: String?
        let town: String?
        let village: String?
        let county: String?
    }
}

private struct OSRMRouteResponse: Decodable {
    let code: String
    let routes: [Route]
    struct Route: Decodable {
        let distance: Double
        let duration: Double
        let geometry: Geometry
    }
    struct Geometry: Decodable { let coordinates: [[Double]] }
}

private struct OSRMTripResponse: Decodable {
    let code: String
    let waypoints: [Waypoint]
    struct Waypoint: Decodable {
        let waypointIndex: Int?
        enum CodingKeys: String, CodingKey { case waypointIndex = "waypoint_index" }
    }
}

private struct OSRMNearestResponse: Decodable {
    let code: String
    let waypoints: [Waypoint]
    struct Waypoint: Decodable { let location: [Double] }
}

enum OSMError: LocalizedError {
    case invalidRequest, geocoderUnavailable, routerUnavailable, noRoute, addressNotFound(String)
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "Не удалось сформировать запрос OpenStreetMap/OSRM"
        case .geocoderUnavailable: "Сервис поиска адресов OpenStreetMap временно недоступен"
        case .routerUnavailable: "Маршрутизатор OSRM временно недоступен"
        case .noRoute: "OSRM не смог построить автомобильный маршрут"
        case .addressNotFound(let value): "OpenStreetMap не нашёл адрес: \(value)"
        }
    }
}
