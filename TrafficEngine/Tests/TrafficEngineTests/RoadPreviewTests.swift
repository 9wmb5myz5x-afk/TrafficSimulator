import XCTest
@testable import TrafficEngine

/// Drawing a road shows what it will do before it is built.
final class RoadPreviewTests: XCTestCase {

    /// The preview predicts the edit exactly and leaves the network untouched.
    func testPreviewMatchesTheEditAndChangesNothing() throws {
        let sim = ScenarioFactory.make(.corridor, side: .right, seed: 3)
        let editor = Editor(sim: sim)
        let stroke = [Vector2(300, -200), Vector2(302, -60), Vector2(300, 120), Vector2(298, 220)]
        let before = sim.network.data, version = sim.network.version
        let p = editor.previewRoad(stroke, roadClass: .local)
        XCTAssertTrue(p.ok, "\(String(describing: p.error))")
        XCTAssertEqual(sim.network.data, before, "a preview changes nothing")
        XCTAssertEqual(sim.network.version, version)
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(p.junctions, 1, "one crossing")
        XCTAssertEqual(p.ends.count, 2)
        XCTAssertEqual(p.ends.filter(\.attached).count, 0, "both ends are new dead ends")
        let made = try editor.drawRoad(stroke, roadClass: .local)
        XCTAssertEqual(p.centrelines.count, made.count)
        for (line, id) in zip(p.centrelines, made) {
            XCTAssertEqual(line, sim.network.centreline(of: id)?.points, "the preview shows the road that gets built")
        }
    }

    /// Bad drags are explained before release, the same way the edit would fail.
    func testPreviewExplainsWhatIsWrong() {
        let sim = ScenarioFactory.make(.corridor, side: .right, seed: 3)
        let editor = Editor(sim: sim)
        XCTAssertEqual(editor.previewRoad([Vector2(0, 300), Vector2(8, 300)], roadClass: .local).error, .tooShort)
        XCTAssertEqual(editor.previewRoad([Vector2(0, 300), Vector2(100, 300)], roadClass: .local, lanes: 9).error, .invalidLanes)
        XCTAssertEqual(editor.previewRoad([Vector2(0, 300), Vector2(9000, 300)], roadClass: .local).error, .outOfBounds)
        // A hairpin is too sharp.
        let hairpin = [Vector2(0, 300), Vector2(60, 300), Vector2(62, 304), Vector2(0, 306)]
        let p = editor.previewRoad(hairpin, roadClass: .local)
        XCTAssertFalse(p.ok)
        XCTAssertThrowsError(try editor.drawRoad(hairpin, roadClass: .local))
    }

    /// A highway passes over the streets it crosses (no junctions), and its
    /// new junctions are raised with it.
    func testHighwayPassesOverStreets() throws {
        let sim = ScenarioFactory.make(.corridor, side: .right, seed: 3)
        let editor = Editor(sim: sim)
        let stroke = [Vector2(300, -250), Vector2(300, 250)]
        let p = editor.previewRoad(stroke, roadClass: .highway, lanes: 2)
        XCTAssertTrue(p.ok, "\(String(describing: p.error))")
        XCTAssertEqual(p.junctions, 0)
        XCTAssertGreaterThanOrEqual(p.overpasses, 1)
        let nodes = sim.network.data.nodes.count
        let made = try editor.drawRoad(stroke, roadClass: .highway, lanes: 2)
        XCTAssertEqual(made.count, 1)
        for n in sim.network.allNodes where n.id.raw >= nodes { XCTAssertEqual(n.level, 1) }
    }

    /// Fast enough to run while the finger moves, even on the biggest map.
    func testPreviewIsQuick() {
        let sim = ScenarioFactory.make(.stressCity, side: .right, seed: 1)
        let editor = Editor(sim: sim)
        let b = sim.terrain
        let stroke = [Vector2(b.minCorner.x + 100, 0), Vector2(b.maxCorner.x - 100, 40)]
        _ = editor.previewRoad(stroke, roadClass: .collector)
        let t0 = Date()
        for _ in 0..<5 { _ = editor.previewRoad(stroke, roadClass: .collector) }
        let each = Date().timeIntervalSince(t0) / 5
        print("preview on stressCity: \(Int(each * 1000)) ms")
        XCTAssertLessThan(each, 0.5)
    }
}
