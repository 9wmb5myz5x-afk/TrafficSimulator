//
//  Screenshot.swift
//  TrafficSimulatorUITests
//
//  Captures a screenshot as an XCTAttachment and, when the CI passes
//  SCREENSHOT_DIR (via TEST_RUNNER_SCREENSHOT_DIR), also writes a PNG to disk so
//  the workflow can upload it as an artifact.
//

import XCTest

enum Screenshot {
    static func capture(_ app: XCUIApplication, named name: String) {
        // The screen, not the element: element screenshots of a landscape app
        // come out rotated and cropped on some simulator runtimes.
        _ = app
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Screenshot \(name)") { $0.add(attachment) }

        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(device).png")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    /// Rotate to landscape once the app is running (rotating before launch
    /// leaves the app laid out in portrait on a landscape screen).
    static func landscape(_ app: XCUIApplication) {
        guard XCUIDevice.shared.orientation != .landscapeLeft else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
}
