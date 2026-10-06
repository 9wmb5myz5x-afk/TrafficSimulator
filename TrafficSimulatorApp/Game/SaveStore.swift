//
//  SaveStore.swift
//  TrafficSimulator
//
//  Named cities on disk: one JSON `SaveFile` per city in
//  Application Support/Cities. Writes are atomic (a crash mid-save never
//  leaves a half-written file). Reading never traps: a damaged file is listed
//  as unreadable and loading it reports an error.
//

import Foundation
import TrafficEngine

struct SavedCity: Identifiable, Hashable {
    /// File name (without extension).
    let id: String
    let name: String
    let savedAt: Date
    let summary: String
    let isAutosave: Bool
    /// False when the file could not be read (shown as damaged).
    let readable: Bool
}

enum SaveStore {
    static let autosaveID = "Autosave"

    static var directory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Cities", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }

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

    /// A file-system-safe id for a city name.
    static func fileID(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "City" : String(cleaned.prefix(60))
    }

    static func write(_ save: SaveFile, id: String) throws {
        let data = try encoder().encode(save)
        try data.write(to: url(for: id), options: .atomic)
    }

    static func read(_ id: String) throws -> SaveFile {
        let data = try Data(contentsOf: url(for: id))
        return try decoder().decode(SaveFile.self, from: data)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Just enough of a save for the list (keys not named here are skipped).
    private struct Header: Decodable {
        struct State: Decodable { var clockSeconds: Double; var population: Int }
        var schema: Int
        var name: String
        var savedAt: Double
        var state: State
    }

    static func list() -> [SavedCity] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [SavedCity] = []
        for f in files where f.pathExtension == "json" {
            let id = f.deletingPathExtension().lastPathComponent
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let data = try? Data(contentsOf: f), let h = try? decoder().decode(Header.self, from: data) {
                let day = Int(h.state.clockSeconds / 86400) + 1
                out.append(SavedCity(id: id, name: h.name, savedAt: Date(timeIntervalSince1970: h.savedAt),
                                     summary: "Day \(day) · \(h.state.population) residents",
                                     isAutosave: id == autosaveID, readable: h.schema <= SaveFile.currentSchema))
            } else {
                out.append(SavedCity(id: id, name: id, savedAt: modified, summary: "Damaged file",
                                     isAutosave: id == autosaveID, readable: false))
            }
        }
        return out.sorted { $0.savedAt > $1.savedAt }
    }

    /// UI tests: plant a damaged save to exercise the error path.
    static func plantCorruptSave() {
        try? Data("{\"schema\": 1, \"name\": \"Broken".utf8).write(to: url(for: "Broken City"), options: .atomic)
    }
}
