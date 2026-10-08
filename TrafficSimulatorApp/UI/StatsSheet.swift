//
//  StatsSheet.swift
//  TrafficSimulator
//
//  Time-series charts (Swift Charts) and the per-junction Level of Service table.
//

import SwiftUI
import Charts
import TrafficEngine

struct StatsSheet: View {
    @ObservedObject var game: GameController
    @Environment(\.dismiss) private var dismiss
    @State private var data: GameController.StatsData?

    var body: some View {
        NavigationStack {
            Group {
                if let data {
                    List {
                        Section("Traffic") {
                            chart("Trips per hour", data.history.map { ($0.clock, $0.tripsPerHour) }, unit: "")
                            chart("Average speed (km/h)", data.history.map { ($0.clock, $0.averageSpeed * 3.6) }, unit: "km/h")
                            chart("Average trip (min)", data.history.map { ($0.clock, $0.averageTripTime / 60) }, unit: "min")
                            chart("Vehicles on the road", data.history.map { ($0.clock, Double($0.activeVehicles)) }, unit: "")
                        }
                        Section("Police") {
                            if data.responseTimes.isEmpty {
                                Text("No responses yet.").foregroundStyle(.secondary)
                            } else {
                                let mean = data.responseTimes.reduce(0, +) / Double(data.responseTimes.count)
                                LabeledContent("Mean response", value: String(format: "%.1f min", mean / 60))
                                // The latest 60 calls (the mean above covers them all).
                                Chart(Array(data.responseTimes.suffix(60).enumerated()), id: \.offset) { item in
                                    BarMark(x: .value("Call", item.offset), y: .value("Minutes", item.element / 60))
                                        .foregroundStyle(Theme.color(.policeBlue))
                                }
                                .frame(height: 120)
                                .accessibilityLabel("Police response times")
                            }
                        }
                        Section("Junctions (Level of Service)") {
                            if data.junctions.isEmpty { Text("No data yet.").foregroundStyle(.secondary) }
                            ForEach(data.junctions.prefix(40)) { row in
                                HStack {
                                    Text(row.name).font(.callout)
                                    Spacer()
                                    Text(String(format: "%.0f s", row.delay)).monospacedDigit().foregroundStyle(.secondary)
                                    Text(row.los.rawValue)
                                        .font(.system(.callout, design: .rounded).weight(.heavy))
                                        .frame(width: 28, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(losColor(row.los).opacity(0.25)))
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Statistics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { game.loadStats { data = $0 } }
        .accessibilityIdentifier("stats.sheet")
    }

    private func chart(_ title: String, _ points: [(Double, Double)], unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if points.count < 2 {
                Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(Array(points.enumerated()), id: \.offset) { item in
                    LineMark(x: .value("Clock (h)", item.element.0 / 3600), y: .value(title, item.element.1))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.color(.uiAccent))
                }
                .frame(height: 110)
                .accessibilityLabel(title)
            }
        }
        .padding(.vertical, 4)
    }

    private func losColor(_ l: LevelOfService) -> Color {
        switch l {
        case .A, .B: return Theme.color(.signalGreen)
        case .C, .D: return Theme.color(.signalAmber)
        case .E, .F: return Theme.color(.signalRed)
        }
    }
}
