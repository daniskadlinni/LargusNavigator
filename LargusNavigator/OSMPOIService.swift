import Foundation

actor OSMPOIService {
    static let shared = OSMPOIService()

    private let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.nchc.org.tw/api/interpreter")!
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 22
        config.timeoutIntervalForResource = 28
        return URLSession(configuration: config)
    }()

    private var cache: [String: [RoutePOI]] = [:]

    /// Loads POIs in small batches. A failed batch does not cancel the whole route.
    func pointsAlong(coordinates: [OSMCoordinate]) async -> [RoutePOI] {
        guard !coordinates.isEmpty else { return [] }

        // 8 representative points keeps public Overpass load reasonable.
        let samples = sample(coordinates, maxCount: 8)
        let radius = 12_000

        var combined: [RoutePOI] = []
        var seen = Set<String>()

        for (index, point) in samples.enumerated() {
            let key = cacheKey(point: point, radius: radius)

            let batch: [RoutePOI]
            if let cached = cache[key] {
                batch = cached
            } else {
                batch = await fetchBatch(point: point, radius: radius, preferredEndpoint: index)
                cache[key] = batch
            }

            for poi in batch where seen.insert(poi.id).inserted {
                combined.append(poi)
            }
        }

        return cap(combined)
    }

    private func fetchBatch(point: OSMCoordinate, radius: Int, preferredEndpoint: Int) async -> [RoutePOI] {
        let around = "(around:\(radius),\(point.latitude),\(point.longitude))"
        let query = """
        [out:json][timeout:18];
        (
          nwr\(around)[amenity=fuel];
          nwr\(around)[amenity~"^(restaurant|cafe|fast_food)$"];
          nwr\(around)[tourism~"^(hotel|motel|guest_house|hostel)$"];
          nwr\(around)[shop~"^(supermarket|convenience|grocery)$"];
        );
        out center tags;
        """

        // Rotate the first server so long routes do not hammer one endpoint.
        let ordered = (0..<endpoints.count).map { endpoints[(preferredEndpoint + $0) % endpoints.count] }

        for endpoint in ordered {
            if let items = try? await request(endpoint: endpoint, query: query) {
                return items
            }
        }
        return []
    }

    private func request(endpoint: URL, query: String) async throws -> [RoutePOI] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("LargusNavigator/1.7.8 (personal macOS route planner)", forHTTPHeaderField: "User-Agent")
        request.httpBody = formEncodedData(name: "data", value: query)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OSMPOIError.serviceUnavailable
        }

        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
        var result: [RoutePOI] = []
        var seen = Set<String>()

        for element in decoded.elements {
            guard
                let category = category(tags: element.tags),
                let coordinate = element.coordinate
            else { continue }

            let key = "\(element.type)-\(element.id)"
            guard seen.insert(key).inserted else { continue }

            let name = element.tags?["name"]
                ?? element.tags?["brand"]
                ?? element.tags?["operator"]
                ?? category.title

            result.append(RoutePOI(
                id: key,
                name: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                category: category,
                distanceFromRouteKM: 0,
                estimatedDetourMinutes: 0
            ))
        }
        return result
    }

    private func cap(_ result: [RoutePOI]) -> [RoutePOI] {
        var capped: [RoutePOI] = []
        for category in RoutePOICategory.allCases {
            let items = result
                .filter { $0.category == category }
                .sorted { lhs, rhs in
                    let lNamed = lhs.name != category.title
                    let rNamed = rhs.name != category.title
                    if lNamed != rNamed { return lNamed && !rNamed }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            capped.append(contentsOf: items.prefix(40))
        }
        return capped
    }

    private func cacheKey(point: OSMCoordinate, radius: Int) -> String {
        let lat = (point.latitude * 100).rounded() / 100
        let lon = (point.longitude * 100).rounded() / 100
        return "\(lat):\(lon):\(radius)"
    }

    private func formEncodedData(name: String, value: String) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedName)=\(encodedValue)".data(using: .utf8)
    }

    private func category(tags: [String: String]?) -> RoutePOICategory? {
        guard let tags else { return nil }
        if tags["amenity"] == "fuel" { return .fuel }

        if let amenity = tags["amenity"],
           ["restaurant", "cafe", "fast_food"].contains(amenity) {
            return .food
        }

        if let tourism = tags["tourism"],
           ["hotel", "motel", "guest_house", "hostel"].contains(tourism) {
            return .hotel
        }

        if let shop = tags["shop"],
           ["supermarket", "convenience", "grocery"].contains(shop) {
            return .grocery
        }

        return nil
    }

    private func sample(_ coordinates: [OSMCoordinate], maxCount: Int) -> [OSMCoordinate] {
        guard coordinates.count > maxCount else { return coordinates }
        var result: [OSMCoordinate] = []
        for index in 0..<maxCount {
            let fraction = Double(index) / Double(maxCount - 1)
            let rawIndex = Int(round(fraction * Double(coordinates.count - 1)))
            result.append(coordinates[min(rawIndex, coordinates.count - 1)])
        }
        return result
    }
}

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: OverpassCenter?
    let tags: [String: String]?

    var coordinate: OSMCoordinate? {
        if let lat, let lon {
            return OSMCoordinate(latitude: lat, longitude: lon)
        }
        if let center {
            return OSMCoordinate(latitude: center.lat, longitude: center.lon)
        }
        return nil
    }
}

private struct OverpassCenter: Decodable {
    let lat: Double
    let lon: Double
}

enum OSMPOIError: LocalizedError {
    case serviceUnavailable

    var errorDescription: String? {
        "Сервисы OpenStreetMap POI временно недоступны"
    }
}
