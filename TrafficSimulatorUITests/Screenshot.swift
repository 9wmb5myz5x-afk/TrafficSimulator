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
        try? upright(shot).write(to: url)
    }

    /// PNG bytes with the pixels rotated upright. The raw capture is in the
    /// screen's native portrait orientation with only an EXIF flag for
    /// landscape, which many viewers ignore.
    static func upright(_ shot: XCUIScreenshot) -> Data {
        let orientation: UIImage.Orientation
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: orientation = .left
        case .landscapeRight: orientation = .right
        case .portraitUpsideDown: orientation = .down
        default: orientation = .up
        }
        // Only when the raw pixels really are portrait (never rotate twice).
        guard orientation != .up, let cg = shot.image.cgImage,
              orientation == .down || cg.width < cg.height else { return shot.pngRepresentation }
        let oriented = UIImage(cgImage: cg, scale: 1, orientation: orientation)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: oriented.size, format: format).image { _ in
            oriented.draw(in: CGRect(origin: .zero, size: oriented.size))
        }
        return image.pngData() ?? shot.pngRepresentation
    }

    /// Rotate to landscape once the app is running (rotating before launch
    /// leaves the app laid out in portrait on a landscape screen).
    static func landscape(_ app: XCUIApplication) {
        guard XCUIDevice.shared.orientation != .landscapeLeft else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
}
