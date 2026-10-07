//
//  GameplayTests.swift
//  TrafficSimulatorUITests
//
//  Level-4 game-layer tests (§10.5):
//   • build a small town with gestures: a road, homes, a shop and a police
//     station → trips start and a patrol car appears;
//   • save → terminate → relaunch → load → the city matches;
//   • a corrupted save → no crash, an error is shown;
//   • rotate, background and foreground → no crash, the sim resumes.
//

import XCTest

final class GameplayTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Helpers

    /// The camera the town test pins: centre (-380, 0), 0.5 m per point —
    /// everything below stays clear of the side buttons even on an iPhone SE.
    private let camera = (x: -380.0, y: 0.0, scale: 0.5)

    /// Screen coordinate of a world point under the pinned camera.
    private func point(_ app: XCUIApplication, _ wx: Double, _ wy: Double) -> XCUICoordinate {
        let frame = app.windows.firstMatch.frame
        let sx = frame.width / 2 + (wx - camera.x) / camera.scale
        let sy = frame.height / 2 - (wy - camera.y) / camera.scale
        return app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sx, dy: sy))
    }

    private func value(_ app: XCUIApplication, _ id: String) -> Int {
        Int((app.descendants(matching: .any)[id].value as? String) ?? "0") ?? 0
    }

    /// Wait until `condition` holds, polling every half second.
    @discardableResult
    private func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    private func tap(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let b = app.buttons[id]
        XCTAssertTrue(b.waitForExistence(timeout: 5), "\(id) not found", file: file, line: line)
        b.tap()
    }

    private func toast(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["feedback.toast"] }

    // MARK: Tests

    func testBuildSmallTownSaveRelaunchAndLoad() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetSaves", "-openCity", "emptyLand", "-startHour", "7",
                               "-camera", "\(camera.x),\(camera.y),\(camera.scale)"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["hud.vehicles"].waitForExistence(timeout: 15))
        Screenshot.landscape(app)
        XCTAssertEqual(value(app, "hud.population"), 0, "empty land starts empty")

        // A street east from the regional road's cul-de-sac.
        tap(app, "palette.roads")
        XCTAssertTrue(app.buttons["tool.road"].waitForExistence(timeout: 3))
        point(app, -520, 0).press(forDuration: 0.15, thenDragTo: point(app, -265, 0))
        // The toast is brief (a slow accessibility snapshot can miss it): an
        // undoable edit is the same evidence.
        let drew = wait(6) { toast(app).exists || app.buttons["tool.undo"].isEnabled }
        Screenshot.capture(app, named: "build-road")
        XCTAssertTrue(drew, "no feedback after drawing")

        // Homes on both sides, a shop, an office and a police station.
        tap(app, "palette.homes")
        for x in stride(from: -490.0, through: -310, by: 30) {
            point(app, x, 24).tap()
            point(app, x, -24).tap()
        }
        tap(app, "palette.work")
        point(app, -320, -30).tap()
        tap(app, "tool.office")
        point(app, -290, 30).tap()
        tap(app, "palette.services")
        point(app, -420, -32).tap()
        tap(app, "palette.inspect")
        Screenshot.capture(app, named: "build-town")

        // Run fast: people move in, trips start and a patrol car drives out.
        tap(app, "run.speed.10")
        XCTAssertTrue(wait(90) { value(app, "hud.population") > 0 }, "nobody moved in")
        XCTAssertTrue(wait(120) { value(app, "hud.vehicles") > 0 }, "no trips started")
        XCTAssertTrue(wait(120) { value(app, "hud.patrols") > 0 }, "no patrol car appeared")
        Screenshot.capture(app, named: "build-town-running")

        // Save under a name.
        tap(app, "run.pause")
        let population = value(app, "hud.population")
        tap(app, "map.save")
        let name = app.textFields["save.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Test Town\n")      // Return saves
        if !wait(4, { !app.buttons["save.confirm"].exists }), app.buttons["save.confirm"].isHittable {
            app.buttons["save.confirm"].tap()
        }
        let closed = wait(10) { !app.buttons["save.confirm"].exists }
        if !closed { Screenshot.capture(app, named: "save-sheet-stuck") }
        XCTAssertTrue(closed, "save sheet did not close")

        // Terminate, relaunch, load.
        app.terminate()
        let again = XCUIApplication()
        again.launch()
        XCTAssertTrue(again.descendants(matching: .any)["title.logo"].waitForExistence(timeout: 10))
        Screenshot.landscape(again)
        tap(again, "title.load")
        let row = again.buttons["load.Test Town"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "saved city not listed")
        row.tap()
        XCTAssertTrue(again.descendants(matching: .any)["hud.vehicles"].waitForExistence(timeout: 15), "loaded city did not open")
        // Same city: the population (which only changes slowly) matches.
        XCTAssertTrue(wait(5) { abs(value(again, "hud.population") - population) <= max(2, population / 10) },
                      "population \(value(again, "hud.population")) vs saved \(population)")
        XCTAssertEqual(again.state, .runningForeground)
        Screenshot.capture(again, named: "loaded-town")
    }

    func testCorruptedSaveShowsErrorWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetSaves", "-corruptSave"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["title.logo"].waitForExistence(timeout: 10))
        tap(app, "title.load")
        let row = app.buttons["load.Broken City"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "damaged save not listed")
        row.tap()
        let alert = app.alerts["Couldn't load this city"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "no error shown for a damaged save")
        Screenshot.capture(app, named: "corrupt-save")
        alert.buttons["OK"].tap()
        XCTAssertEqual(app.state, .runningForeground, "app crashed")
        XCTAssertTrue(app.descendants(matching: .any)["title.logo"].waitForExistence(timeout: 5))
    }

    func testRotateBackgroundAndResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-openCity", "signalGrid"]
        app.launch()
        let clock = app.descendants(matching: .any)["hud.clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCUIDevice.shared.orientation = .landscapeRight
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(app.state, .runningForeground)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        // The simulation resumes: the clock moves again.
        XCTAssertTrue(clock.waitForExistence(timeout: 10))
        let before = clock.label
        XCTAssertTrue(wait(15) { clock.label != before }, "simulation did not resume after foregrounding")
    }
}
