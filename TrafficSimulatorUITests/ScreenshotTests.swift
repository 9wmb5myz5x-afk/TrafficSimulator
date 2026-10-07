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

    private func open(_ map: String, _ extra: [String] = [], landscape: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openCity", map] + extra
        app.launch()
        _ = app.descendants(matching: .any)["hud.vehicles"].waitForExistence(timeout: 15)
        if landscape { Screenshot.landscape(app) }
        return app
    }

    /// Cars on their driveways in the suburb at rush hour, and the
    /// countryside where the regional road leaves the map.
    func testDrivewaysAndCountryside() {
        var app = open("suburb", ["-startHour", "7.6", "-camera", "-110,-45,0.09"])
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        Screenshot.capture(app, named: "driveways")
        app.terminate()
        app = open("suburb", ["-startHour", "7.6", "-camera", "760,10,1.1"])
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        Screenshot.capture(app, named: "countryside")
    }

    /// Portrait: every control on screen, and the traffic dial.
    func testPortraitLayoutAndTrafficDial() {
        XCUIDevice.shared.orientation = .portrait
        let app = open("downtown", ["-startHour", "8"], landscape: false)
        settle(6)
        Screenshot.capture(app, named: "portrait")
        for id in ["map.overlay", "map.traffic", "map.recentre", "map.stats", "map.save", "map.menu", "palette.roads"] {
            let b = app.buttons[id]
            XCTAssertTrue(b.exists && b.isHittable, "\(id) is not on screen in portrait")
        }
        app.buttons["map.traffic"].tap()
        let heavy = app.buttons["traffic.preset.heavy"]
        XCTAssertTrue(heavy.waitForExistence(timeout: 5))
        heavy.tap()
        settle(1)
        Screenshot.capture(app, named: "traffic-dial")
        app.swipeDown()
        settle(20)
        Screenshot.capture(app, named: "heavy-traffic")
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testStarterMapsAtRushHour() {
        for map in ["signalGrid", "suburb", "downtown", "highwayTown", "roundaboutVillage", "stressCity"] {
            // Close enough to see the cars, with the morning peak building.
            let app = open(map, ["-startHour", "7.6", "-zoom", "0.45"])
            settle(12)
            Screenshot.capture(app, named: "rush-\(map)")
            app.terminate()
        }
    }

    func testCloseUpNightAndLeftHand() {
        // A central signalised junction (grid nodes sit every 240 × 210 m).
        var app = open("signalGrid", ["-startHour", "8", "-camera", "480,210,0.12"])
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
        // Some simulated time first, so the charts have data to show.
        if app.buttons["run.speed.30"].isHittable {
            app.buttons["run.speed.30"].tap()
            settle(12)
            if app.buttons["run.speed.1"].isHittable { app.buttons["run.speed.1"].tap() }
        }
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
