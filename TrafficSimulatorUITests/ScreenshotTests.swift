//
//  ScreenshotTests.swift
//  TrafficSimulatorUITests
//
//  Level-5 screenshot set (§10.6): reviewed by eye after every CI run.
//

import XCTest

final class ScreenshotTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func open(_ map: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openCity", map] + extra
        app.launch()
        _ = app.descendants(matching: .any)["hud.vehicles"].waitForExistence(timeout: 15)
        Screenshot.landscape(app)
        return app
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testStarterMapsAtRushHour() {
        for map in ["signalGrid", "suburb", "downtown", "highwayTown", "roundaboutVillage", "stressCity"] {
            let app = open(map, ["-startHour", "7.6"])
            settle(10)
            Screenshot.capture(app, named: "rush-\(map)")
            app.terminate()
        }
    }

    func testCloseUpNightAndLeftHand() {
        var app = open("signalGrid", ["-startHour", "8", "-zoom", "0.12"])
        settle(10)
        Screenshot.capture(app, named: "closeup-lanes")
        app.terminate()
        app = open("suburb", ["-startHour", "21.5"])
        settle(8)
        Screenshot.capture(app, named: "night")
        app.terminate()
        app = open("roundaboutVillage", ["-startHour", "8", "-leftHand", "-zoom", "0.25"])
        settle(8)
        Screenshot.capture(app, named: "left-hand")
        app.terminate()
    }

    func testInspectorStatsAndOverlays() {
        let app = open("signalGrid", ["-startHour", "8", "-zoom", "0.3", "-debugOverlay"])
        settle(6)
        // Tap around the middle of the map until something is inspected.
        let map = app.descendants(matching: .any)["city.map"]
        let inspector = app.descendants(matching: .any)["inspector"]
        for dx in [0.5, 0.45, 0.55, 0.4, 0.6] where !inspector.exists {
            map.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            _ = inspector.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(inspector.exists, "Tapping the map opens an inspector card")
        Screenshot.capture(app, named: "inspector")
        app.buttons["map.overlay"].tap()          // → congestion
        settle(3)
        Screenshot.capture(app, named: "overlay-congestion")
        app.buttons["map.overlay"].tap()          // → police coverage
        settle(3)
        Screenshot.capture(app, named: "overlay-coverage")
        app.buttons["map.stats"].tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
        settle(1)
        Screenshot.capture(app, named: "stats")
    }

    func testDesignPreview() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["title.design"].waitForExistence(timeout: 10))
        app.buttons["title.design"].tap()
        XCTAssertTrue(app.navigationBars["Design"].waitForExistence(timeout: 5))
        settle(1)
        Screenshot.capture(app, named: "design-preview")
    }
}
