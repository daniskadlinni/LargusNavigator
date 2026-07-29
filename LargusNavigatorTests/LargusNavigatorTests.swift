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
    }
}
