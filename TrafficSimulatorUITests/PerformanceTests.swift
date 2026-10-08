//
//  PerformanceTests.swift
//  TrafficSimulatorUITests
//
//  Responsiveness under load: on a busy map running fast, tap through every
//  part of the interface (palette, tools, map buttons, sheets, the map
//  itself, drawing and building) and record, per action, the main-thread
//  hitches and how long work waits for the simulation queue. The app's
//  `-perfProbe` probe measures; this test drives and writes a report
//  (`perf-<map>-<device>.txt` next to the screenshots).
//

import XCTest

final class PerformanceTests: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private struct Probe {
        var frames = 0, max = 0, recentMax = 0, h50 = 0, h100 = 0, h250 = 0, h1000 = 0, simWait = 0
        init(_ s: String) {
            for part in s.split(separator: ";") {
                let kv = part.split(separator: "=")
                guard kv.count == 2, let v = Int(kv[1]) else { continue }
                switch kv[0] {
                case "frames": frames = v
                case "max": max = v
                case "recentMax": recentMax = v
                case "h50": h50 = v
                case "h100": h100 = v
                case "h250": h250 = v
                case "h1000": h1000 = v
                case "simWait": simWait = v
                default: break
                }
            }
        }
    }

    private func probe(_ app: XCUIApplication) -> Probe {
        Probe((app.descendants(matching: .any)["perf.probe"].value as? String) ?? "")
    }

    private func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func open(_ map: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-openCity", map, "-startHour", "7.5", "-perfProbe"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["hud.vehicles"].waitForExistence(timeout: 20))
        Screenshot.landscape(app)
        pause(2)
        return app
    }

    private func tapIfPresent(_ app: XCUIApplication, _ id: String) {
        let b = app.buttons[id]
        if b.waitForExistence(timeout: 3), b.isHittable { b.tap() }
    }

    /// Run `body`, let things settle, and record what it cost.
    private func measure(_ app: XCUIApplication, _ name: String, into report: inout [String],
                         worst: inout [String: Int], settle: TimeInterval = 1.5, _ body: () -> Void) {
        let before = probe(app)
        let t0 = Date()
        body()
        pause(settle)
        let after = probe(app)
        let wall = Int(Date().timeIntervalSince(t0) * 1000)
        let line = String(format: "%-28@ hitches>100ms=%2d >250ms=%2d >1s=%d  worstFrame(4s)=%5dms  simQueueWait=%4dms  (%d ms incl. settle)",
                          name as NSString, after.h100 - before.h100, after.h250 - before.h250, after.h1000 - before.h1000,
                          after.recentMax, after.simWait, wall)
        report.append(line)
        worst[name] = after.recentMax
    }

    private func runSession(map: String) {
        let app = open(map)
        var report = ["map: \(map)  device: \(UIDevice.current.name)"]
        var worst: [String: Int] = [:]

        measure(app, "idle at 1x", into: &report, worst: &worst, settle: 4) {}
        measure(app, "speed 10x (idle 5 s)", into: &report, worst: &worst, settle: 5) { tapIfPresent(app, "run.speed.10") }
        for c in ["roads", "homes", "work", "services", "junctions", "bulldoze", "inspect"] {
            measure(app, "palette \(c)", into: &report, worst: &worst) { tapIfPresent(app, "palette.\(c)") }
        }
        for k in 1...3 {
            measure(app, "overlay cycle \(k)", into: &report, worst: &worst, settle: 2.5) { tapIfPresent(app, "map.overlay") }
        }
        measure(app, "traffic sheet open", into: &report, worst: &worst) { tapIfPresent(app, "map.traffic") }
        measure(app, "traffic preset heavy", into: &report, worst: &worst) { tapIfPresent(app, "traffic.preset.heavy") }
        measure(app, "traffic sheet close", into: &report, worst: &worst) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        }
        measure(app, "stats open", into: &report, worst: &worst, settle: 2) { tapIfPresent(app, "map.stats") }
        measure(app, "stats close", into: &report, worst: &worst) {
            let done = app.buttons["Done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
        }
        let map = app.windows.firstMatch
        for (k, p) in [(0.45, 0.45), (0.55, 0.6), (0.35, 0.55), (0.62, 0.4)].enumerated() {
            measure(app, "tap map (select) \(k + 1)", into: &report, worst: &worst) {
                map.coordinate(withNormalizedOffset: CGVector(dx: p.0, dy: p.1)).tap()
            }
        }
        measure(app, "double-tap zoom in", into: &report, worst: &worst) {
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        }
        measure(app, "pan", into: &report, worst: &worst) {
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)))
        }
        measure(app, "recentre", into: &report, worst: &worst) { tapIfPresent(app, "map.recentre") }
        // Edits: a road across the middle of town (junctions, a full map update).
        tapIfPresent(app, "palette.roads")
        measure(app, "draw road", into: &report, worst: &worst, settle: 3) {
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.62))
                .press(forDuration: 0.15, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.58)))
        }
        tapIfPresent(app, "palette.homes")
        measure(app, "place a house", into: &report, worst: &worst, settle: 2) {
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66)).tap()
        }
        measure(app, "undo", into: &report, worst: &worst, settle: 2) { tapIfPresent(app, "tool.undo") }
        measure(app, "undo again", into: &report, worst: &worst, settle: 2) { tapIfPresent(app, "tool.undo") }
        tapIfPresent(app, "palette.inspect")
        measure(app, "speed 30x (idle 6 s)", into: &report, worst: &worst, settle: 6) { tapIfPresent(app, "run.speed.30") }

        let final = probe(app)
        report.append("total: frames=\(final.frames) worstFrame=\(final.max)ms hitches>100ms=\(final.h100) >250ms=\(final.h250) >1s=\(final.h1000)")
        Report.write(report.joined(separator: "\n"), named: "perf-\(map)")
        Screenshot.capture(app, named: "perf-\(map)")
        XCTAssertEqual(app.state, .runningForeground, "\(map): the app kept running")
    }

    func testResponsivenessDowntown() { runSession(map: "downtown") }
    func testResponsivenessStressCity() { runSession(map: "stressCity") }
}

/// Text reports next to the screenshots (CI publishes them).
enum Report {
    static func write(_ text: String, named name: String) {
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Report \(name)") { $0.add(attachment) }
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(device).txt"), atomically: true, encoding: .utf8)
    }
}
