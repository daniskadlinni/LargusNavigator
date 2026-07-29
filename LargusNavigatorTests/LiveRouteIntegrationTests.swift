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
    }

    private let scenarios: [Scenario] = [
        .init(name: "Voronezh_Anna", addresses: ["Москва, Байкальская улица, 17к1", "Воронеж", "Анна, Воронежская область", "Замьяны, Астраханская область"], minDistanceKM: 1100, maxDistanceKM: 1800, minFuelStations: 8),
        .init(name: "Tambov", addresses: ["Москва, Байкальская улица, 17к1", "Тамбов", "Замьяны, Астраханская область"], minDistanceKM: 1100, maxDistanceKM: 1800, minFuelStations: 8),
        .init(name: "Voronezh_Anna_Akhtubinsk", addresses: ["Москва, Байкальская улица, 17к1", "Воронеж", "Анна, Воронежская область", "Ахтубинск", "Замьяны, Астраханская область"], minDistanceKM: 1200, maxDistanceKM: 1900, minFuelStations: 8)
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

            let fuels = await OSMFuelService.shared.majorFuelStations(along: route.geometry)
            XCTAssertGreaterThanOrEqual(fuels.count, scenario.minFuelStations, "\(scenario.name): suspiciously few major fuel stations: \(fuels.count)")
        }
    }
}
