import Foundation
@preconcurrency import MapKit
import CoreLocation

@MainActor
final class StableFuelService {
    static let shared = StableFuelService()

    private(set) var lastDiagnostics = "поиск ещё не запускался"
    private(set) var lastCoverageIsUseful = false
    private var lastYandexMessage = ""
    private var lastOSMMessage = ""

    private init() {}

    func stations(
        along route: [OSMCoordinate],
        onProgress: (@Sendable (FuelSearchProgress) async -> Void)? = nil
    ) async -> [RoutePOI] {
        guard route.count >= 2 else { return [] }
        lastOSMMessage = ""

        let yandex = await yandexStations(along: route)
        let yandexCoverage = coverage(of: yandex, along: route)
        if yandexCoverage.isUseful {
            let result = orderedAndSpread(yandex, along: route)
            lastCoverageIsUseful = true
            lastDiagnostics = diagnostics(yandexCount: yandex.count, appleCount: 0, osmCount: 0, result: result, route: route)
            return result
        }

        // Apple and OSM are independent. Running them together avoids making a
        // long route wait for all Apple samples before Overpass even starts.
        async let appleLookup = appleStations(along: route)
        async let osmLookup = OSMFuelService.shared.majorFuelStations(along: route, onProgress: onProgress)
        let (apple, osm) = await (appleLookup, osmLookup)
        lastOSMMessage = await OSMFuelService.shared.lastDiagnostics
        let primary = merge(yandex, apple)
        let appleCoverage = coverage(of: primary, along: route)

        if appleCoverage.isUseful {
            let result = orderedAndSpread(primary, along: route)
            lastCoverageIsUseful = true
            lastDiagnostics = diagnostics(
                yandexCount: yandex.count,
                appleCount: apple.count,
                osmCount: osm.count,
                result: result,
                route: route
            )
            return result
        }

        let merged = merge(primary, osm)
        let result = orderedAndSpread(merged, along: route)
        lastCoverageIsUseful = coverage(of: result, along: route).isUseful
        lastDiagnostics = diagnostics(
            yandexCount: yandex.count,
            appleCount: apple.count,
            osmCount: osm.count,
            result: result,
            route: route
        )
        return result
    }

    private func yandexStations(along route: [OSMCoordinate]) async -> [RoutePOI] {
        #if ROUTE_SMOKE
        // The command-line CI smoke tester has no WebKit UI or app Keychain.
        return []
        #else
        lastYandexMessage = "поиск организаций требует платный API — отключён"
        return []
        #endif
    }

    private func appleStations(along route: [OSMCoordinate]) async -> [RoutePOI] {
        let samples = sampleByDistance(route, spacingMeters: 60_000, maxCount: 30)

        var result: [RoutePOI] = []
        var seen = Set<String>()

        for (index, sample) in samples.enumerated() {
            let center = CLLocationCoordinate2D(
                latitude: sample.latitude,
                longitude: sample.longitude
            )

            let request = MKLocalPointsOfInterestRequest(
                center: center,
                radius: 42_000
            )
            request.pointOfInterestFilter = MKPointOfInterestFilter(
                including: [.gasStation]
            )

            let countBeforeSample = result.count

            do {
                let response = try await MKLocalSearch(request: request).start()
                appendStations(
                    from: Array(response.mapItems.prefix(25)),
                    route: route,
                    result: &result,
                    seen: &seen
                )
            } catch {
                // The text search below still gets a chance to fill this sample.
            }

            // Apple POI categories are sparse on some Russian road sections.
            // Run a natural-language search only where the categorized request
            // produced no new route-adjacent station.
            if result.count == countBeforeSample {
                let textRequest = MKLocalSearch.Request()
                textRequest.naturalLanguageQuery = "АЗС"
                textRequest.region = MKCoordinateRegion(
                    center: center,
                    latitudinalMeters: 84_000,
                    longitudinalMeters: 84_000
                )

                if let response = try? await MKLocalSearch(request: textRequest).start() {
                    appendStations(
                        from: Array(response.mapItems.prefix(30)),
                        route: route,
                        result: &result,
                        seen: &seen
                    )
                }
            }

            if index < samples.count - 1 {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        return orderedAndSpread(result, along: route)
    }

    private func appendStations(
        from items: [MKMapItem],
        route: [OSMCoordinate],
        result: inout [RoutePOI],
        seen: inout Set<String>
    ) {
        for item in items {
            let rawName = item.name ?? ""
            guard let displayName = Self.displayNameForFuelStation(rawName) else {
                continue
            }

            let coordinate = item.placemark.coordinate
            let distance = minimumDistanceFromRoute(
                point: coordinate,
                route: route
            )
            guard distance <= 4_000 else { continue }

            let key = dedupeKey(brand: displayName, coordinate: coordinate)
            guard seen.insert(key).inserted else { continue }

            let km = distance / 1000.0
            result.append(
                RoutePOI(
                    id: "apple-fuel-\(key)",
                    name: displayName,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    category: .fuel,
                    distanceFromRouteKM: km,
                    estimatedDetourMinutes: max(
                        1,
                        Int((km / 35.0 * 60.0 + 1.0).rounded(.up))
                    ),
                    roadKilometer: nil,
                    roadReference: nil
                )
            )
        }
    }

    private struct Coverage {
        let count: Int
        let thirds: [Int]
        let maxGapKM: Double

        var isUseful: Bool {
            count >= 10
                && thirds.allSatisfy { $0 >= 1 }
                && maxGapKM <= 80
        }
    }

    private func coverage(
        of points: [RoutePOI],
        along route: [OSMCoordinate]
    ) -> Coverage {
        let routeLength = routeLengthKM(route)
        guard routeLength > 0 else {
            return Coverage(count: points.count, thirds: [0, 0, 0], maxGapKM: .infinity)
        }

        let chainages = points.map {
            chainageKM(
                latitude: $0.latitude,
                longitude: $0.longitude,
                route: route
            )
        }.sorted()

        var thirds = [0, 0, 0]
        for km in chainages {
            let fraction = min(0.999999, max(0, km / routeLength))
            thirds[min(2, Int(fraction * 3))] += 1
        }

        let values = [0.0] + chainages + [routeLength]
        var maxGap = 0.0
        if values.count >= 2 {
            for i in 1..<values.count {
                maxGap = max(maxGap, values[i] - values[i - 1])
            }
        }

        return Coverage(
            count: points.count,
            thirds: thirds,
            maxGapKM: maxGap
        )
    }

    private func orderedAndSpread(
        _ points: [RoutePOI],
        along route: [OSMCoordinate]
    ) -> [RoutePOI] {
        let networks = points.filter {
            Self.isRecognisedFuelNetwork($0.name)
        }
        let networkOnly = spreadAndCap(networkCandidates(networks, along: route), maxCount: 100)

        // Prefer a clean map containing only known networks. Regional and
        // generic stations are used only when removing them would leave a
        // route-wide coverage hole.
        if coverage(of: networkOnly, along: route).isUseful {
            return enrichRouteMetadata(networkOnly, route: route)
        }

        var supplemented = networks
        var occupiedKM = networks.map {
            chainageKM(latitude: $0.latitude, longitude: $0.longitude, route: route)
        }
        let fallback = points
            .filter { !Self.isRecognisedFuelNetwork($0.name) }
            .map { point in
                (point, chainageKM(latitude: point.latitude, longitude: point.longitude, route: route))
            }
            .sorted { $0.1 < $1.1 }

        // Add a local operator only when no known network covers roughly the
        // surrounding 70 km. This preserves safety without flooding the map.
        for (point, km) in fallback {
            let nearest = occupiedKM.map { abs($0 - km) }.min() ?? .infinity
            if nearest > 35 {
                supplemented.append(point)
                occupiedKM.append(km)
            }
        }

        let selected = spreadAndCap(networkCandidates(supplemented, along: route), maxCount: 100)
        return enrichRouteMetadata(selected, route: route)
    }

    private func networkCandidates(
        _ points: [RoutePOI],
        along route: [OSMCoordinate]
    ) -> [RoutePOI] {
        points.sorted {
            chainageKM(latitude: $0.latitude, longitude: $0.longitude, route: route)
                < chainageKM(latitude: $1.latitude, longitude: $1.longitude, route: route)
        }
    }

    private func enrichRouteMetadata(
        _ points: [RoutePOI],
        route: [OSMCoordinate]
    ) -> [RoutePOI] {
        points.map { point in
            let metadata = routeMetadata(
                latitude: point.latitude,
                longitude: point.longitude,
                route: route
            )
            return RoutePOI(
                id: point.id,
                name: point.name,
                latitude: point.latitude,
                longitude: point.longitude,
                category: point.category,
                distanceFromRouteKM: point.distanceFromRouteKM,
                estimatedDetourMinutes: point.estimatedDetourMinutes,
                roadKilometer: point.roadKilometer,
                roadReference: point.roadReference,
                routeProgressKM: metadata.progressKM,
                routeSide: metadata.side
            )
        }
    }

    private func routeMetadata(
        latitude: Double,
        longitude: Double,
        route: [OSMCoordinate]
    ) -> (progressKM: Double, side: RouteSide) {
        guard route.count >= 2 else { return (0, .unknown) }
        let point = OSMCoordinate(latitude: latitude, longitude: longitude)
        let refLat = latitude * .pi / 180
        let metersLat = 111_320.0
        let metersLon = max(1.0, 111_320.0 * cos(refLat))
        var cumulative = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        var bestProgress = 0.0
        var bestCross = 0.0

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
            let px = ax + fraction * dx
            let py = ay + fraction * dy
            let distance = sqrt(px * px + py * py)
            let segmentLength = haversineMeters(a, b)
            if distance < bestDistance {
                bestDistance = distance
                bestProgress = (cumulative + segmentLength * fraction) / 1000.0
                bestCross = dx * (-ay) - dy * (-ax)
            }
            cumulative += segmentLength
        }

        let side: RouteSide
        if bestDistance < 25 {
            side = .onRoute
        } else {
            side = bestCross > 0 ? .left : .right
        }
        return (bestProgress, side)
    }

    private func spreadAndCap(_ ordered: [RoutePOI], maxCount: Int) -> [RoutePOI] {
        var accepted: [RoutePOI] = []
        for point in ordered {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let tooClose = accepted.contains {
                location.distance(
                    from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                ) < 7_000
            }

            if !tooClose {
                accepted.append(point)
            }
        }

        guard accepted.count > maxCount else { return accepted }

        // Sample the already route-ordered list across its complete range.
        // prefix(maxCount) used to discard the end of long routes entirely.
        return (0..<maxCount).map { index in
            let fraction = Double(index) / Double(maxCount - 1)
            let raw = Int((fraction * Double(accepted.count - 1)).rounded())
            return accepted[min(raw, accepted.count - 1)]
        }
    }

    private func merge(_ a: [RoutePOI], _ b: [RoutePOI]) -> [RoutePOI] {
        var result = a

        for item in b {
            let loc = CLLocation(latitude: item.latitude, longitude: item.longitude)
            let duplicate = result.contains {
                loc.distance(
                    from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                ) < 2_000
            }
            if !duplicate {
                result.append(item)
            }
        }

        return result
    }

    private func diagnostics(
        yandexCount: Int,
        appleCount: Int,
        osmCount: Int,
        result: [RoutePOI],
        route: [OSMCoordinate]
    ) -> String {
        let resultCoverage = coverage(of: result, along: route)
        let yandexDetails = yandexCount == 0 && !lastYandexMessage.isEmpty
            ? " (\(lastYandexMessage))"
            : ""
        let osmDetails = osmCount == 0 && !lastOSMMessage.isEmpty
            ? " (\(lastOSMMessage))"
            : ""
        let networkCount = result.lazy.filter { Self.isRecognisedFuelNetwork($0.name) }.count
        return "Яндекс \(yandexCount)\(yandexDetails), Apple \(appleCount), OSM \(osmCount)\(osmDetails), итог \(result.count) (сетевых \(networkCount)), "
            + "трети \(resultCoverage.thirds[0])/\(resultCoverage.thirds[1])/\(resultCoverage.thirds[2]), "
            + String(format: "макс. пробел %.0f км", resultCoverage.maxGapKM)
    }

    nonisolated static func displayNameForFuelStation(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !looksGasOnly(trimmed) else { return nil }

        if let brand = recognisedFuelBrand(in: trimmed) {
            return brand
        }

        // MapKit has already classified these results as gas stations. Do not
        // discard a valid liquid-fuel station merely because Apple returned a
        // regional operator or a generic name instead of one of our aliases.
        return trimmed.isEmpty ? "АЗС" : trimmed
    }

    nonisolated static func isRecognisedFuelNetwork(_ value: String) -> Bool {
        recognisedFuelBrand(in: value) != nil
    }

    nonisolated private static func recognisedFuelBrand(in value: String) -> String? {
        let n = normalize(value)
        let brands: [(String, [String])] = [
            ("Лукойл", ["лукойл", "lukoil"]),
            ("Газпромнефть", ["газпромнефть", "газпром нефть", "gazpromneft", "gazprom neft", "g-drive"]),
            ("Роснефть", ["роснефть", "rosneft", "рн азс", "рн-азс"]),
            ("Татнефть", ["татнефть", "tatneft"]),
            ("Башнефть", ["башнефть", "bashneft"]),
            ("Teboil", ["teboil", "тебойл"]),
            ("Нефтьмагистраль", ["нефтьмагистраль", "neftmagistral"]),
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
            aliases.contains { n.contains($0) }
        }?.0
    }

    nonisolated private static func looksGasOnly(_ value: String) -> Bool {
        let n = normalize(value)
        return [
            "агзс", "агнкс", "метан", "пропан",
            "lpg", "cng", "газомотор"
        ].contains { n.contains($0) }
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private func dedupeKey(
        brand: String,
        coordinate: CLLocationCoordinate2D
    ) -> String {
        let lat = (coordinate.latitude * 10_000).rounded() / 10_000
        let lon = (coordinate.longitude * 10_000).rounded() / 10_000
        return "\(brand.lowercased())|\(lat)|\(lon)"
    }

    private func sampleByDistance(
        _ coordinates: [OSMCoordinate],
        spacingMeters: Double,
        maxCount: Int
    ) -> [OSMCoordinate] {
        guard coordinates.count >= 2 else { return coordinates }

        var cumulative: [Double] = [0]
        var total = 0.0

        for i in 1..<coordinates.count {
            total += haversineMeters(coordinates[i - 1], coordinates[i])
            cumulative.append(total)
        }

        let count = min(maxCount, max(2, Int(total / spacingMeters) + 1))
        let spacing = total / Double(max(1, count - 1))

        var result: [OSMCoordinate] = []
        var index = 0

        for n in 0..<count {
            let target = min(total, Double(n) * spacing)

            while index < cumulative.count - 2,
                  cumulative[index + 1] < target {
                index += 1
            }

            let next = min(index + 1, coordinates.count - 1)
            let d0 = cumulative[index]
            let d1 = cumulative[next]
            let fraction = d1 > d0 ? (target - d0) / (d1 - d0) : 0

            let a = coordinates[index]
            let b = coordinates[next]

            result.append(
                OSMCoordinate(
                    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                    longitude: a.longitude + (b.longitude - a.longitude) * fraction
                )
            )
        }

        return result
    }

    private func routeLengthKM(_ route: [OSMCoordinate]) -> Double {
        guard route.count >= 2 else { return 0 }
        var total = 0.0

        for i in 1..<route.count {
            total += haversineMeters(route[i - 1], route[i]) / 1000.0
        }

        return total
    }

    private func chainageKM(
        latitude: Double,
        longitude: Double,
        route: [OSMCoordinate]
    ) -> Double {
        guard route.count >= 2 else { return 0 }

        let point = OSMCoordinate(latitude: latitude, longitude: longitude)
        let step = max(1, route.count / 1800)

        var cumulative = 0.0
        var bestChainage = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        var previousIndex = 0

        var index = step
        while index < route.count {
            cumulative += haversineMeters(route[previousIndex], route[index])

            let distance = haversineMeters(point, route[index])
            if distance < bestDistance {
                bestDistance = distance
                bestChainage = cumulative / 1000.0
            }

            previousIndex = index
            index += step
        }

        if previousIndex != route.count - 1 {
            cumulative += haversineMeters(route[previousIndex], route[route.count - 1])
            let distance = haversineMeters(point, route[route.count - 1])
            if distance < bestDistance {
                bestChainage = cumulative / 1000.0
            }
        }

        return bestChainage
    }

    private func minimumDistanceFromRoute(
        point: CLLocationCoordinate2D,
        route: [OSMCoordinate]
    ) -> Double {
        guard route.count >= 2 else { return .greatestFiniteMagnitude }

        let refLat = point.latitude * .pi / 180
        let metersLat = 111_320.0
        let metersLon = max(1.0, 111_320.0 * cos(refLat))
        let step = max(1, route.count / 1800)

        func xy(_ c: OSMCoordinate) -> (Double, Double) {
            (
                (c.longitude - point.longitude) * metersLon,
                (c.latitude - point.latitude) * metersLat
            )
        }

        var best = Double.greatestFiniteMagnitude
        var i = 0

        while i < route.count - 1 {
            let j = min(i + step, route.count - 1)
            let a = xy(route[i])
            let b = xy(route[j])
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let length2 = dx * dx + dy * dy
            let t = length2 > 0.0001
                ? max(0, min(1, -(a.0 * dx + a.1 * dy) / length2))
                : 0

            let x = a.0 + t * dx
            let y = a.1 + t * dy
            best = min(best, sqrt(x * x + y * y))
            i = j
        }

        return best
    }

    private func haversineMeters(
        _ a: OSMCoordinate,
        _ b: OSMCoordinate
    ) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180
        let p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180

        let h =
            sin(dp / 2) * sin(dp / 2)
            + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)

        return 2 * r * atan2(sqrt(h), sqrt(1 - h))
    }
}
