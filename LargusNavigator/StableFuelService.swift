import Foundation
@preconcurrency import MapKit
import CoreLocation

@MainActor
final class StableFuelService {
    static let shared = StableFuelService()

    private init() {}

    func stations(along route: [OSMCoordinate]) async -> [RoutePOI] {
        guard route.count >= 2 else { return [] }

        let apple = await appleStations(along: route)
        let appleCoverage = coverage(of: apple, along: route)

        if appleCoverage.isUseful {
            return orderedAndSpread(apple, along: route)
        }

        let osm = await OSMFuelService.shared.majorFuelStations(along: route)
        let merged = merge(apple, osm)
        return orderedAndSpread(merged, along: route)
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

            do {
                let response = try await MKLocalSearch(request: request).start()

                for item in response.mapItems.prefix(25) {
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
            } catch {
                continue
            }

            if index < samples.count - 1 {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        return orderedAndSpread(result, along: route)
    }

    private struct Coverage {
        let count: Int
        let thirds: [Int]
        let maxGapKM: Double

        var isUseful: Bool {
            count >= 10
                && thirds.allSatisfy { $0 >= 1 }
                && maxGapKM <= 240
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
        let ordered = points.sorted {
            chainageKM(latitude: $0.latitude, longitude: $0.longitude, route: route)
                < chainageKM(latitude: $1.latitude, longitude: $1.longitude, route: route)
        }

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
                if accepted.count >= 100 { break }
            }
        }
        return accepted
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
            ("Газпром", ["газпром", "gazprom"])
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
