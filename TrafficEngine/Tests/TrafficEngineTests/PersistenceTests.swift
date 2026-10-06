import XCTest
import Foundation
@testable import TrafficEngine

final class PersistenceTests: XCTestCase {

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    private func hashRun(_ sim: Simulation, steps: Int) -> UInt64 {
        var h = TraceHasher()
        for k in 0..<steps {
            sim.step()
            if k % 20 == 0 { h.combine(sim.traceHash()) }
        }
        return h.value
    }

    /// save → JSON → load → continue is bit-identical to an uninterrupted run.
    func testSaveLoadResumesBitIdentically() throws {
        for (kind, side) in [(ScenarioKind.suburb, DrivingSide.right), (.signalGrid, .left), (.highwayTown, .right)] {
            let a = ScenarioFactory.make(kind, side: side, seed: 4)
            a.run(seconds: 700)          // mid-morning: vehicles, police, signals, lane changes in flight
            let data = try Self.encoder().encode(a.makeSave(name: "test"))
            let save = try Self.decoder().decode(SaveFile.self, from: data)
            let b = try Simulation.restore(save)
            XCTAssertEqual(a.traceHash(), b.traceHash(), "\(kind) \(side): state after load")
            let steps = Int(600 / a.config.dt)
            XCTAssertEqual(hashRun(a, steps: steps), hashRun(b, steps: steps), "\(kind) \(side): continuation diverged")
            XCTAssertEqual(a.vehicles.count, b.vehicles.count)
            XCTAssertEqual(a.metrics.aggregate.completedTrips, b.metrics.aggregate.completedTrips)
        }
    }

    func testCorruptSavesAreRejectedNotCrashed() throws {
        let sim = ScenarioFactory.make(.corridor, side: .right, seed: 1)
        sim.run(seconds: 120)
        let data = try Self.encoder().encode(sim.makeSave(name: "ok"))
        // Truncated JSON.
        XCTAssertThrowsError(try Self.decoder().decode(SaveFile.self, from: data.prefix(data.count / 2)))
        // A future schema.
        var save = try Self.decoder().decode(SaveFile.self, from: data)
        save.schema = 99
        XCTAssertThrowsError(try Simulation.restore(save))
        // A vehicle on a road that is not in the network.
        save = try Self.decoder().decode(SaveFile.self, from: data)
        if !save.state.vehicles.isEmpty {
            save.state.vehicles[0].track = .edge(EdgeID(99_999))
            XCTAssertThrowsError(try Simulation.restore(save))
        }
        // Garbage.
        XCTAssertThrowsError(try Self.decoder().decode(SaveFile.self, from: Data("not json".utf8)))
    }
}
