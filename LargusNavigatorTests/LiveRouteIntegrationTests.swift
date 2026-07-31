import XCTest
@testable import LargusNavigator

final class LiveRouteIntegrationTests: XCTestCase {
    private let osrm = "https://router.project-osrm.org"

    private struct Scenario {
        let name: String
        let addresses: [String]
        let minDistanceKM: Double
        let maxDistanceKM: Double
        let minFuelStations: Int
        let maxAllowedGapKM: Double
    }

    private let scenarios: [Scenario] = [
        .init(name: "Voronezh_Anna", addresses: ["Москва, Байкальская улица, 17к1", "Воронеж", "Анна, Воронежская область", "Замьяны, Астраханская область"], minDistanceKM: 1100, maxDistanceKM: 1800, minFuelStations: 8, maxAllowedGapKM: 320),
        .init(name: "Tambov", addresses: ["Москва, Байкальская улица, 17к1", "Тамбов", "Замьяны, Астраханская область"], minDistanceKM: 1100, maxDistanceKM: 1800, minFuelStations: 8, maxAllowedGapKM: 320),
        .init(name: "Voronezh_Anna_Akhtubinsk", addresses: ["Москва, Байкальская улица, 17к1", "Воронеж", "Анна, Воронежская область", "Ахтубинск", "Замьяны, Астраханская область"], minDistanceKM: 1200, maxDistanceKM: 1900, minFuelStations: 8, maxAllowedGapKM: 320)
    ]

    func testLiveControlRoutesAndFuelCoverage() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_NETWORK_TESTS"] == "1", "Set LIVE_NETWORK_TESTS=1 in CI")

        for scenario in scenarios {
            let points = try await OSMRouteEngine.shared.geocode(scenario.addresses)
            let route = try await OSMRouteEngine.shared.exactRoute(points: points, osrmBase: osrm)
            let distanceKM = route.distanceMeters / 1000
            XCTAssertGreaterThan(distanceKM, scenario.minDistanceKM, scenario.name)
            XCTAssertLessThan(distanceKM, scenario.maxDistanceKM, scenario.name)
            XCTAssertGreaterThan(route.geometry.count, 100, scenario.name)

            let fuels = await StableFuelService.shared.stations(along: route.geometry)
            XCTAssertGreaterThanOrEqual(fuels.count, scenario.minFuelStations, "\(scenario.name): suspiciously few major fuel stations: \(fuels.count)")

            let chainages = fuelChainages(
                fuels: fuels,
                route: route.geometry
            ).sorted()
            let thirds = thirdCoverage(
                chainagesKM: chainages,
                routeDistanceKM: distanceKM
            )
            let maxGap = routeGaps(
                chainagesKM: chainages,
                routeDistanceKM: distanceKM
            ).max() ?? distanceKM

            XCTAssertTrue(
                thirds.allSatisfy { $0 >= 1 },
                "\(scenario.name): stations do not cover all route thirds: \(thirds)"
            )
            XCTAssertLessThanOrEqual(
                maxGap,
                scenario.maxAllowedGapKM,
                "\(scenario.name): maximum fuel gap is \(maxGap) km"
            )
        }
    }

    private func fuelChainages(
        fuels: [RoutePOI],
        route: [OSMCoordinate]
    ) -> [Double] {
        guard route.count >= 2 else { return [] }

        var cumulative = Array(repeating: 0.0, count: route.count)
        for index in 1..<route.count {
            cumulative[index] = cumulative[index - 1]
                + haversineKM(route[index - 1], route[index])
        }

        return fuels.map { fuel in
            let station = OSMCoordinate(
                latitude: fuel.latitude,
                longitude: fuel.longitude
            )
            let nearest = route.indices.min {
                haversineKM(station, route[$0]) < haversineKM(station, route[$1])
            } ?? 0
            return cumulative[nearest]
        }
    }

    private func routeGaps(
        chainagesKM: [Double],
        routeDistanceKM: Double
    ) -> [Double] {
        let values = [0.0] + chainagesKM.sorted() + [routeDistanceKM]
        return (1..<values.count).map {
            max(0, values[$0] - values[$0 - 1])
        }
    }

    private func thirdCoverage(
        chainagesKM: [Double],
        routeDistanceKM: Double
    ) -> [Int] {
        guard routeDistanceKM > 0 else { return [0, 0, 0] }
        var result = [0, 0, 0]
        for km in chainagesKM {
            let fraction = min(0.999999, max(0, km / routeDistanceKM))
            result[min(2, Int(fraction * 3))] += 1
        }
        return result
    }

    private func haversineKM(
        _ a: OSMCoordinate,
        _ b: OSMCoordinate
    ) -> Double {
        let radius = 6_371.0
        let latitudeA = a.latitude * .pi / 180
        let latitudeB = b.latitude * .pi / 180
        let latitudeDelta = (b.latitude - a.latitude) * .pi / 180
        let longitudeDelta = (b.longitude - a.longitude) * .pi / 180
        let h = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(latitudeA) * cos(latitudeB)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return 2 * radius * atan2(sqrt(h), sqrt(1 - h))
    }
}
