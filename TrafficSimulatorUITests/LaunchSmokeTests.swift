//
//  LaunchSmokeTests.swift
//  TrafficSimulatorUITests
//
//  Level-4: the title appears within 5 s; New City opens a map on which
//  traffic appears (the HUD vehicle count, an accessibility value, rises).
//

import XCTest

final class LaunchSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func vehicleCount(_ app: XCUIApplication) -> Int {
        Int((app.descendants(matching: .any)["hud.vehicles"].value as? String) ?? "0") ?? 0
    }

    private func waitForTraffic(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let vehicles = app.descendants(matching: .any)["hud.vehicles"]
        XCTAssertTrue(vehicles.waitForExistence(timeout: 15), "HUD vehicle counter not found", file: file, line: line)
        let first = vehicleCount(app)
        var latest = first
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && latest <= first {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            latest = vehicleCount(app)
        }
        XCTAssertGreaterThan(latest, first, "Vehicle count did not increase within 10 s", file: file, line: line)
    }

    func testTitleThenNewCityAndTrafficFlows() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App did not reach the foreground")
        XCTAssertTrue(app.descendants(matching: .any)["title.logo"].waitForExistence(timeout: 5), "Title not visible within 5 s")
        Screenshot.capture(app, named: "title")
        app.buttons["title.new"].tap()
        let create = app.buttons["new.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        waitForTraffic(app)
        XCTAssertEqual(app.state, .runningForeground, "App crashed or was backgrounded")
        Screenshot.capture(app, named: "launch")
    }
}
