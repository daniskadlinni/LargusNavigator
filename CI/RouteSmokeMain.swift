import Foundation

@main
struct RouteSmokeMain {
    struct Scenario {
        let name: String
        let addresses: [String]
        let minDistanceKM: Double
        let maxDistanceKM: Double
        let minFuelStations: Int
        let maxAllowedGapKM: Double
    }

    static let scenarios: [Scenario] = [
        .init(
            name: "1 — Воронеж + Анна",
            addresses: [
                "Москва, Байкальская улица, 17к1",
                "Воронеж",
                "Анна, Воронежская область",
                "Замьяны, Астраханская область"
            ],
            minDistanceKM: 1100,
            maxDistanceKM: 1800,
            minFuelStations: 8,
            maxAllowedGapKM: 320
        ),
        .init(
            name: "2 — Тамбов",
            addresses: [
                "Москва, Байкальская улица, 17к1",
                "Тамбов",
                "Замьяны, Астраханская область"
            ],
            minDistanceKM: 1100,
            maxDistanceKM: 1800,
            minFuelStations: 8,
            maxAllowedGapKM: 320
        ),
        .init(
            name: "3 — Воронеж + Анна + Ахтубинск",
            addresses: [
                "Москва, Байкальская улица, 17к1",
                "Воронеж",
                "Анна, Воронежская область",
                "Ахтубинск",
                "Замьяны, Астраханская область"
            ],
            minDistanceKM: 1200,
            maxDistanceKM: 1900,
            minFuelStations: 8,
            maxAllowedGapKM: 320
        )
    ]

    static func main() async {
        var failures: [String] = []

        print("============================================================")
        print("Largus Navigator — LIVE ROUTE / FUEL COVERAGE TEST")
        print("Production sources: OSMRouteEngine + StableFuelService (MapKit → OSM fallback)")
        print("============================================================")

        for scenario in scenarios {
            do {
                print("\n▶︎ \(scenario.name)")
                print("  \(scenario.addresses.joined(separator: " → "))")

                print("  [1/3] Geocoding…")
                let points = try await OSMRouteEngine.shared.geocode(scenario.addresses)
                print("  [2/3] OSRM route…")
                let route = try await OSMRouteEngine.shared.exactRoute(
                    points: points,
                    osrmBase: "https://router.project-osrm.org"
                )

                let distanceKM = route.distanceMeters / 1000.0
                print(String(format: "  Route: %.1f km, geometry: %d points", distanceKM, route.geometry.count))

                guard distanceKM >= scenario.minDistanceKM,
                      distanceKM <= scenario.maxDistanceKM else {
                    throw SmokeError("route length \(Int(distanceKM)) km is outside expected range")
                }

                guard route.geometry.count > 100 else {
                    throw SmokeError("route geometry is suspiciously short")
                }

                print("  [3/3] Fuel scan started at \(ISO8601DateFormatter().string(from: Date()))")
                let fuelStart = Date()
                let fuels = await StableFuelService.shared.stations(along: route.geometry)
                let fuelElapsed = Date().timeIntervalSince(fuelStart)
                print(String(format: "  Fuel scan finished in %.1f sec", fuelElapsed))
                print("  Major fuel stations found: \(fuels.count)")

                guard fuels.count >= scenario.minFuelStations else {
                    throw SmokeError("only \(fuels.count) major fuel stations found")
                }

                let chainages = fuelChainages(
                    fuels: fuels,
                    route: route.geometry
                ).sorted()

                let gaps = routeGaps(
                    chainagesKM: chainages,
                    routeDistanceKM: distanceKM
                )
                let maxGap = gaps.max() ?? distanceKM

                let thirds = thirdCoverage(
                    chainagesKM: chainages,
                    routeDistanceKM: distanceKM
                )

                print(String(format: "  Maximum gap between fuel coverage points: %.1f km", maxGap))
                print("  Fuel stations by route thirds: \(thirds[0]) / \(thirds[1]) / \(thirds[2])")

                if let largest = largestGapDescription(
                    chainagesKM: chainages,
                    routeDistanceKM: distanceKM
                ) {
                    print("  Largest empty span: \(largest)")
                }

                guard maxGap <= scenario.maxAllowedGapKM else {
                    throw SmokeError(
                        String(
                            format: "fuel coverage gap %.0f km exceeds %.0f km",
                            maxGap,
                            scenario.maxAllowedGapKM
                        )
                    )
                }

                guard thirds.allSatisfy({ $0 >= 1 }) else {
                    throw SmokeError(
                        "fuel stations are concentrated in only part of the route; thirds = \(thirds)"
                    )
                }

                print("  ✅ PASS")
            } catch {
                let message = "\(scenario.name): \(error.localizedDescription)"
                failures.append(message)
                print("  ❌ FAIL — \(message)")
            }
        }

        print("\n============================================================")
        if failures.isEmpty {
            print("✅ ALL 3 ROUTES PASSED")
            print("============================================================")
            exit(0)
        } else {
            print("❌ FAILED \(failures.count) ROUTE(S)")
            for failure in failures {
                print(" - \(failure)")
            }
            print("============================================================")
            exit(1)
        }
    }

    static func fuelChainages(
        fuels: [RoutePOI],
        route: [OSMCoordinate]
    ) -> [Double] {
        guard route.count >= 2 else { return [] }

        var cumulative: [Double] = Array(repeating: 0, count: route.count)
        for index in 1..<route.count {
            cumulative[index] = cumulative[index - 1] + haversineKM(
                route[index - 1],
                route[index]
            )
        }

        return fuels.compactMap { fuel in
            let station = OSMCoordinate(
                latitude: fuel.latitude,
                longitude: fuel.longitude
            )

            var bestIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (index, coordinate) in route.enumerated() {
                let distance = haversineKM(station, coordinate)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            guard let bestIndex else { return nil }
            return cumulative[bestIndex]
        }
    }

    static func routeGaps(
        chainagesKM: [Double],
        routeDistanceKM: Double
    ) -> [Double] {
        let values = [0.0] + chainagesKM.sorted() + [routeDistanceKM]
        guard values.count >= 2 else { return [routeDistanceKM] }

        return (1..<values.count).map {
            max(0, values[$0] - values[$0 - 1])
        }
    }

    static func thirdCoverage(
        chainagesKM: [Double],
        routeDistanceKM: Double
    ) -> [Int] {
        guard routeDistanceKM > 0 else { return [0, 0, 0] }
        var result = [0, 0, 0]

        for km in chainagesKM {
            let fraction = min(0.999999, max(0, km / routeDistanceKM))
            let index = min(2, Int(fraction * 3))
            result[index] += 1
        }

        return result
    }

    static func largestGapDescription(
        chainagesKM: [Double],
        routeDistanceKM: Double
    ) -> String? {
        let values = [0.0] + chainagesKM.sorted() + [routeDistanceKM]
        guard values.count >= 2 else { return nil }

        var bestStart = 0.0
        var bestEnd = routeDistanceKM
        var bestGap = -1.0

        for index in 1..<values.count {
            let gap = values[index] - values[index - 1]
            if gap > bestGap {
                bestGap = gap
                bestStart = values[index - 1]
                bestEnd = values[index]
            }
        }

        return String(
            format: "~%.0f–%.0f km from route start (%.0f km)",
            bestStart,
            bestEnd,
            bestGap
        )
    }

    static func haversineKM(
        _ a: OSMCoordinate,
        _ b: OSMCoordinate
    ) -> Double {
        let r = 6371.0
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

struct SmokeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
