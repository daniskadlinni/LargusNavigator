import XCTest
@testable import LargusNavigator

final class LargusNavigatorTests: XCTestCase {
    func testFuelCalculation() {
        let distance = 1000.0
        let consumption = 8.8
        let fuel = distance * consumption / 100
        XCTAssertEqual(fuel, 88.0, accuracy: 0.001)
    }

    func testDefaultVehicle() {
        let vehicle = Vehicle()
        XCTAssertEqual(vehicle.name, "Lada Largus")
        XCTAssertEqual(vehicle.powerHP, 106)
        XCTAssertEqual(vehicle.seats, 7)
        XCTAssertEqual(vehicle.fuel, "АИ-95")
        XCTAssertEqual(vehicle.tankCapacityLiters, 50)
    }

    func testFuelStopRecommendationsRespectRange() {
        let stations = stride(from: 100.0, through: 900.0, by: 100.0).map { km in
            RoutePOI(
                id: "station-\(Int(km))",
                name: km == 400 ? "Лукойл" : "Региональная АЗС",
                latitude: 0,
                longitude: km / 1000,
                category: .fuel,
                distanceFromRouteKM: 0,
                estimatedDetourMinutes: 2,
                routeProgressKM: km,
                routeSide: .right
            )
        }
        let result = FuelStopPlanner.recommendations(
            stations: stations,
            routeLengthKM: 1_000,
            vehicle: Vehicle(),
            settings: FuelPlanningSettings()
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0.station.routeProgressKM != nil })
        XCTAssertLessThanOrEqual(result.count, 8)
    }

    func testFuelStationNamesKeepMapKitClassifiedStations() {
        XCTAssertEqual(
            StableFuelService.displayNameForFuelStation("ЛУКОЙЛ №123"),
            "Лукойл"
        )
        XCTAssertEqual(
            StableFuelService.displayNameForFuelStation("Региональная АЗС М4"),
            "Региональная АЗС М4"
        )
        XCTAssertEqual(
            StableFuelService.displayNameForFuelStation(""),
            "АЗС"
        )
    }

    func testGasOnlyStationsAreExcluded() {
        XCTAssertNil(StableFuelService.displayNameForFuelStation("АГНКС Газпром метан"))
        XCTAssertNil(StableFuelService.displayNameForFuelStation("CNG station"))
        XCTAssertNil(StableFuelService.displayNameForFuelStation("Пропан LPG"))
    }
}
