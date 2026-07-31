import Foundation

actor OSMFuelService {
    static let shared = OSMFuelService()

    private let endpoints = [
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
        URL(string: "https://overpass-api.de/api/interpreter")!
    ]

    private(set) var lastDiagnostics = "поиск ещё не запускался"

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    // Successful section results — including successful empty sections.
    // Switching away and back to a route no longer launches a random new search.
    private var sectionCache: [String: [RoutePOI]] = [:]
    private let cacheURL: URL

    private init() {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LargusNavigator", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cacheURL = folder.appendingPathComponent("osm-fuel-sections.json")
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: [RoutePOI]].self, from: data) {
            sectionCache = decoded
        }
    }

    func majorFuelStations(
        along coordinates: [OSMCoordinate],
        onProgress: (@Sendable (FuelSearchProgress) async -> Void)? = nil
    ) async -> [RoutePOI] {
        guard coordinates.count >= 2 else { return [] }

        let sections = splitRoute(
            coordinates,
            sectionLengthMeters: 80_000
        )

        // Reuse stations discovered for other alternatives whenever they are
        // close to this route. Alternatives often share most of their corridor.
        var all = reusableCachedStations(along: coordinates)
        let reusedCount = all.count
        var successfulSections = 0
        var failedSections = 0
        var checkedSections = 0
        await onProgress?(FuelSearchProgress(checkedSections: 0, totalSections: sections.count, failedSections: 0))

        // Public Overpass instances throttle bursts. Route is split into ~120 km sections.
        // We process two small sections at once; each section races independent public endpoints.
        var start = 0
        while start < sections.count {
            if Task.isCancelled { break }
            let end = min(start + 2, sections.count)
            let pair = Array(sections[start..<end])

            var pairResults: [(Int, [RoutePOI]?)] = []

            await withTaskGroup(of: (Int, [RoutePOI]?).self) { group in
                for (localIndex, section) in pair.enumerated() {
                    let absoluteIndex = start + localIndex
                    let key = cacheKey(section)

                    if let cached = sectionCache[key] {
                        pairResults.append((absoluteIndex, cached))
                        continue
                    }

                    group.addTask { [endpoints, session] in
                        let points = await Self.loadSectionReliably(
                            section: section,
                            sectionIndex: absoluteIndex,
                            endpoints: endpoints,
                            session: session
                        )
                        return (absoluteIndex, points)
                    }
                }

                for await result in group {
                    pairResults.append(result)
                }
            }

            pairResults.sort { $0.0 < $1.0 }

            for (index, maybeItems) in pairResults {
                let section = sections[index]
                let key = cacheKey(section)

                if let items = maybeItems {
                    sectionCache[key] = items
                    all.append(contentsOf: items)
                    successfulSections += 1
                } else {
                    failedSections += 1
                }
                checkedSections += 1
            }

            persistCache()
            await onProgress?(FuelSearchProgress(
                checkedSections: checkedSections,
                totalSections: sections.count,
                failedSections: failedSections
            ))

            // loadSectionReliably already tried both Overpass endpoints in two bounded rounds.
            // Keep successful sections: StableFuelService merges them with Apple results and
            // validates final route-wide coverage, so one unavailable public endpoint section
            // must not erase useful stations from every other section.

            start = end
        }

        let result = deduplicate(all)
        let kilometerCount = result.lazy.filter { $0.roadKilometer != nil }.count
        lastDiagnostics = "переиспользовано \(reusedCount), участки \(successfulSections)/\(sections.count), ошибок \(failedSections), найдено \(result.count), с км трассы \(kilometerCount)"
        return result
    }

    private func persistCache() {
        if sectionCache.count > 500 {
            sectionCache = Dictionary(uniqueKeysWithValues: sectionCache.suffix(400))
        }
        guard let data = try? JSONEncoder().encode(sectionCache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func reusableCachedStations(along route: [OSMCoordinate]) -> [RoutePOI] {
        let cached = sectionCache.values.flatMap { $0 }
        return deduplicate(cached.filter { point in
            Self.minimumDistanceMeters(
                point: OSMCoordinate(latitude: point.latitude, longitude: point.longitude),
                route: route
            ) <= 8_000
        })
    }

    private static func loadSectionReliably(
        section: [OSMCoordinate],
        sectionIndex: Int,
        endpoints: [URL],
        session: URLSession
    ) async -> [RoutePOI]? {
        guard section.count >= 2 else { return [] }

        // Two bounded rounds. In each round all independent public endpoints are queried concurrently.
        // The first successful HTTP/JSON response wins, including a valid empty response.
        for attempt in 0..<2 {
            var winner: [RoutePOI]? = nil

            await withTaskGroup(of: [RoutePOI]?.self) { group in
                for offset in 0..<endpoints.count {
                    let endpoint = endpoints[
                        (sectionIndex + attempt + offset) % endpoints.count
                    ]

                    group.addTask {
                        do {
                            return try await requestSection(
                                section: section,
                                endpoint: endpoint,
                                session: session
                            )
                        } catch {
                            return nil
                        }
                    }
                }

                for await result in group {
                    if let result {
                        winner = result
                        group.cancelAll()
                        break
                    }
                }
            }

            if let winner {
                return winner
            }

            if attempt == 0 {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }

        return nil
    }

    private static func requestSection(
        section: [OSMCoordinate],
        endpoint: URL,
        session: URLSession
    ) async throws -> [RoutePOI]? {
        let bbox = expandedBoundingBox(
            section,
            paddingMeters: 10_000
        )

        // Keep this query small: milestones are optional metadata and must not make
        // the safety-critical station lookup fail or time out.
        let query = """
        [out:json][timeout:12];
        (
          nwr["amenity"="fuel"](\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east));
          node["highway"="milestone"](\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east));
        );
        out center tags;
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "LargusNavigator/1.7.8",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = formEncodedData(name: "data", value: query)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            return nil
        }

        let decoded = try JSONDecoder().decode(
            OverpassFuelResponse.self,
            from: data
        )

        let milestones: [RoadMilestone] = decoded.elements.compactMap { element in
            let tags = element.tags ?? [:]
            guard tags["highway"] == "milestone",
                  let coordinate = element.coordinate,
                  minimumDistanceMeters(point: coordinate, route: section) <= 2_500,
                  let kilometer = parseMilestoneDistance(
                    tags["distance"] ?? tags["pk"] ?? tags["ref"] ?? ""
                  )
            else { return nil }

            return RoadMilestone(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                kilometer: kilometer,
                reference: milestoneRoadReference(tags),
                routePositionMeters: routePositionMeters(point: coordinate, route: section)
            )
        }

        var result: [RoutePOI] = []

        for element in decoded.elements {
            let tags = element.tags ?? [:]

            guard tags["amenity"] == "fuel",
                  let c = element.coordinate
            else { continue }

            // Bounding box is only the retrieval window. Enforce the real route
            // corridor after download.
            let distanceToRoute = minimumDistanceMeters(
                point: c,
                route: section
            )
            guard distanceToRoute <= 8_000 else { continue }

            let identity = [
                tags["brand"] ?? "",
                tags["operator"] ?? "",
                tags["name"] ?? ""
            ].joined(separator: " ")

            guard !isGasOnly(tags: tags, identity: identity) else { continue }
            let fallbackName = tags["name"] ?? tags["brand"] ?? tags["operator"] ?? "АЗС"
            let displayName = canonicalBrand(identity) ?? fallbackName
            let chainage = interpolatedRoadKilometer(
                for: c,
                route: section,
                milestones: milestones
            )

            result.append(
                RoutePOI(
                    id: "osm-fuel-\(element.type)-\(element.id)",
                    name: displayName,
                    latitude: c.latitude,
                    longitude: c.longitude,
                    category: .fuel,
                    distanceFromRouteKM: distanceToRoute / 1000.0,
                    estimatedDetourMinutes: max(
                        1,
                        Int(
                            (
                                distanceToRoute / 1000.0 / 35.0 * 60.0
                                + 1.0
                            ).rounded(.up)
                        )
                    ),
                    roadKilometer: chainage?.kilometer,
                    roadReference: chainage?.reference
                )
            )
        }

        // A decoded 200-response with zero stations is a valid checked section.
        return result
    }

    private func splitRoute(
        _ coordinates: [OSMCoordinate],
        sectionLengthMeters: Double
    ) -> [[OSMCoordinate]] {
        guard coordinates.count >= 2 else { return [] }

        var sections: [[OSMCoordinate]] = []
        var current: [OSMCoordinate] = [coordinates[0]]
        var accumulated = 0.0

        for index in 1..<coordinates.count {
            let previous = coordinates[index - 1]
            let point = coordinates[index]

            accumulated += Self.haversineMeters(
                lat1: previous.latitude,
                lon1: previous.longitude,
                lat2: point.latitude,
                lon2: point.longitude
            )
            current.append(point)

            if accumulated >= sectionLengthMeters {
                sections.append(simplify(current, maxPoints: 24))
                current = [point]
                accumulated = 0
            }
        }

        if current.count >= 2 {
            sections.append(simplify(current, maxPoints: 24))
        }

        return sections
    }

    private func simplify(
        _ points: [OSMCoordinate],
        maxPoints: Int
    ) -> [OSMCoordinate] {
        guard points.count > maxPoints else { return points }

        return (0..<maxPoints).map { index in
            let fraction = Double(index) / Double(maxPoints - 1)
            let raw = Int(
                round(fraction * Double(points.count - 1))
            )
            return points[min(raw, points.count - 1)]
        }
    }

    private func cacheKey(_ section: [OSMCoordinate]) -> String {
        guard let first = section.first,
              let last = section.last
        else { return "empty" }

        func q(_ value: Double) -> Double {
            (value * 10_000).rounded() / 10_000
        }

        return "\(q(first.latitude)),\(q(first.longitude))|\(q(last.latitude)),\(q(last.longitude))"
    }

    private func deduplicate(_ points: [RoutePOI]) -> [RoutePOI] {
        var seen = Set<String>()
        var result: [RoutePOI] = []

        for point in points {
            let key = point.id
            if seen.insert(key).inserted {
                result.append(point)
            }
        }

        return result
    }

    private static func expandedBoundingBox(
        _ section: [OSMCoordinate],
        paddingMeters: Double
    ) -> (
        south: Double,
        west: Double,
        north: Double,
        east: Double
    ) {
        let lats = section.map(\.latitude)
        let lons = section.map(\.longitude)

        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0

        let centerLat = (minLat + maxLat) / 2
        let latPad = paddingMeters / 111_320.0
        let lonScale = max(
            10_000.0,
            111_320.0 * cos(centerLat * .pi / 180)
        )
        let lonPad = paddingMeters / lonScale

        return (
            minLat - latPad,
            minLon - lonPad,
            maxLat + latPad,
            maxLon + lonPad
        )
    }

    private static func minimumDistanceMeters(
        point: OSMCoordinate,
        route: [OSMCoordinate]
    ) -> Double {
        guard route.count >= 2 else {
            return .greatestFiniteMagnitude
        }

        let refLat = point.latitude * .pi / 180
        let metersLat = 111_320.0
        let metersLon = max(
            1.0,
            111_320.0 * cos(refLat)
        )

        func xy(_ c: OSMCoordinate) -> (Double, Double) {
            (
                (c.longitude - point.longitude) * metersLon,
                (c.latitude - point.latitude) * metersLat
            )
        }

        var best = Double.greatestFiniteMagnitude

        for i in 0..<(route.count - 1) {
            let a = xy(route[i])
            let b = xy(route[i + 1])
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let len2 = dx * dx + dy * dy

            let t: Double
            if len2 <= 0.0001 {
                t = 0
            } else {
                t = max(
                    0,
                    min(
                        1,
                        -(a.0 * dx + a.1 * dy) / len2
                    )
                )
            }

            let x = a.0 + t * dx
            let y = a.1 + t * dy
            best = min(best, sqrt(x * x + y * y))
        }

        return best
    }

    private static func canonicalBrand(_ value: String) -> String? {
        let n = normalize(value)

        let brands: [(String, [String])] = [
            ("Лукойл", ["лукойл", "lukoil"]),
            ("Газпромнефть", [
                "газпромнефть",
                "газпром нефть",
                "gazpromneft"
            ]),
            ("Роснефть", ["роснефть", "rosneft"]),
            ("Татнефть", ["татнефть", "tatneft"]),
            ("Башнефть", ["башнефть", "bashneft"]),
            ("Teboil", ["teboil", "тебойл"]),
            ("Нефтьмагистраль", [
                "нефтьмагистраль",
                "neftmagistral"
            ]),
            ("Трасса", ["трасса", "trassa"]),
            ("Shell", ["shell", "шелл"]),
            ("Сургутнефтегаз", ["сургутнефтегаз", "surgutneftegas"]),
            ("ПТК", ["птк", "ptk"]),
            ("Газпром", ["газпром", "gazprom"]),
            ("EKA", ["ека", "eka"]),
            ("Neste", ["neste", "несте"]),
            ("Ирбис", ["ирбис", "irbis"]),
            ("Газойл", ["газойл", "gazoil"]),
            ("Калина Ойл", ["калина ойл", "kalina oil"]),
            ("ВТК", ["втк", "vtk"]),
            ("Движение", ["азс движение", "dvizhenie"])
        ]

        return brands.first { _, aliases in
            aliases.contains(where: { n.contains($0) })
        }?.0
    }

    private static func isGasOnly(
        tags: [String: String],
        identity: String
    ) -> Bool {
        let n = normalize(identity)

        if [
            "агзс",
            "агнкс",
            "метан",
            "пропан",
            "lpg",
            "cng",
            "газомотор"
        ].contains(where: { n.contains($0) }) {
            return true
        }

        let hasPetrol =
            tags["fuel:petrol"] == "yes"
            || tags["fuel:diesel"] == "yes"
            || tags.contains(where: {
                $0.key.hasPrefix("fuel:octane_")
                    && $0.value == "yes"
            })

        let hasGas =
            tags["fuel:lpg"] == "yes"
            || tags["fuel:cng"] == "yes"

        return hasGas && !hasPetrol
    }

    private static func parseMilestoneDistance(
        _ raw: String
    ) -> Double? {
        var value = raw
            .lowercased()
            .replacingOccurrences(of: "км", with: "")
            .replacingOccurrences(of: "km", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.contains("+") {
            let parts = value
                .split(separator: "+")
                .map {
                    String($0)
                        .trimmingCharacters(in: .whitespaces)
                }

            if parts.count == 2,
               let km = Double(
                    parts[0].replacingOccurrences(
                        of: ",",
                        with: "."
                    )
               ),
               let meters = Double(
                    parts[1].replacingOccurrences(
                        of: ",",
                        with: "."
                    )
               ) {
                return km + meters / 1000.0
            }
        }

        value = value.replacingOccurrences(of: ",", with: ".")
        return Double(value)
    }

    private static func nearestMilestone(
        latitude: Double,
        longitude: Double,
        milestones: [RoadMilestone],
        maximumMeters: Double
    ) -> RoadMilestone? {
        milestones
            .map { milestone in
                (
                    milestone,
                    haversineMeters(
                        lat1: latitude,
                        lon1: longitude,
                        lat2: milestone.latitude,
                        lon2: milestone.longitude
                    )
                )
            }
            .filter { $0.1 <= maximumMeters }
            .min { $0.1 < $1.1 }?
            .0
    }

    private static func milestoneRoadReference(_ tags: [String: String]) -> String? {
        for key in ["road_ref", "route_ref", "highway_ref"] {
            if let value = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        // In some regions ref contains the road name, while purely numeric ref
        // is the kilometer itself and must not be shown as a highway number.
        if let value = tags["ref"], parseMilestoneDistance(value) == nil {
            return value
        }
        return nil
    }

    private static func interpolatedRoadKilometer(
        for point: OSMCoordinate,
        route: [OSMCoordinate],
        milestones: [RoadMilestone]
    ) -> (kilometer: Double, reference: String?)? {
        guard !milestones.isEmpty else { return nil }
        let position = routePositionMeters(point: point, route: route)
        let ordered = milestones.sorted { $0.routePositionMeters < $1.routePositionMeters }

        let before = ordered.last { $0.routePositionMeters <= position }
        let after = ordered.first { $0.routePositionMeters >= position }

        if let before, let after, before.routePositionMeters != after.routePositionMeters {
            let roadSpan = abs(after.kilometer - before.kilometer)
            let geometrySpan = abs(after.routePositionMeters - before.routePositionMeters) / 1000.0
            let referencesAgree = before.reference == nil || after.reference == nil || before.reference == after.reference

            // Reject unrelated milestones caught by a wide bounding box.
            if referencesAgree, geometrySpan <= 40, roadSpan <= 50,
               roadSpan >= geometrySpan * 0.45, roadSpan <= geometrySpan * 1.8 {
                let fraction = (position - before.routePositionMeters)
                    / (after.routePositionMeters - before.routePositionMeters)
                return (
                    before.kilometer + (after.kilometer - before.kilometer) * fraction,
                    before.reference ?? after.reference
                )
            }
        }

        // A station almost beside a real marker can still use that marker even
        // when the neighbouring marker has not been mapped.
        if let nearest = ordered.min(by: {
            abs($0.routePositionMeters - position) < abs($1.routePositionMeters - position)
        }), abs(nearest.routePositionMeters - position) <= 1_000 {
            return (nearest.kilometer, nearest.reference)
        }
        return nil
    }

    private static func routePositionMeters(
        point: OSMCoordinate,
        route: [OSMCoordinate]
    ) -> Double {
        guard route.count >= 2 else { return 0 }
        let refLat = point.latitude * .pi / 180
        let metersLat = 111_320.0
        let metersLon = max(1.0, 111_320.0 * cos(refLat))
        var cumulative = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        var bestPosition = 0.0

        for index in 0..<(route.count - 1) {
            let a = route[index]
            let b = route[index + 1]
            let ax = (a.longitude - point.longitude) * metersLon
            let ay = (a.latitude - point.latitude) * metersLat
            let bx = (b.longitude - point.longitude) * metersLon
            let by = (b.latitude - point.latitude) * metersLat
            let dx = bx - ax
            let dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0.0001
                ? max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
                : 0
            let projectedX = ax + fraction * dx
            let projectedY = ay + fraction * dy
            let distance = sqrt(projectedX * projectedX + projectedY * projectedY)
            let segmentLength = haversineMeters(
                lat1: a.latitude, lon1: a.longitude,
                lat2: b.latitude, lon2: b.longitude
            )

            if distance < bestDistance {
                bestDistance = distance
                bestPosition = cumulative + segmentLength * fraction
            }
            cumulative += segmentLength
        }
        return bestPosition
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    private static func formEncodedData(
        name: String,
        value: String
    ) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let n =
            name.addingPercentEncoding(
                withAllowedCharacters: allowed
            ) ?? name
        let v =
            value.addingPercentEncoding(
                withAllowedCharacters: allowed
            ) ?? value

        return "\(n)=\(v)".data(using: .utf8)
    }

    private static func haversineMeters(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180

        let a =
            sin(dp / 2) * sin(dp / 2)
            + cos(p1) * cos(p2)
            * sin(dl / 2) * sin(dl / 2)

        return 2 * r * atan2(
            sqrt(a),
            sqrt(1 - a)
        )
    }
}

private struct RoadMilestone {
    let latitude: Double
    let longitude: Double
    let kilometer: Double
    let reference: String?
    let routePositionMeters: Double
}

private struct OverpassFuelResponse: Decodable {
    let elements: [OverpassFuelElement]
}

private struct OverpassFuelElement: Decodable {
    let type: String
    let id: Int64
    let lat: Double?
    let lon: Double?
    let center: OverpassFuelCenter?
    let tags: [String: String]?

    var coordinate: OSMCoordinate? {
        if let lat, let lon {
            return OSMCoordinate(
                latitude: lat,
                longitude: lon
            )
        }

        if let center {
            return OSMCoordinate(
                latitude: center.lat,
                longitude: center.lon
            )
        }

        return nil
    }
}

private struct OverpassFuelCenter: Decodable {
    let lat: Double
    let lon: Double
}
