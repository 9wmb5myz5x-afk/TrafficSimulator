//
//  BuildPalette.swift
//  TrafficSimulator
//
//  The build palette: a row of categories; picking one opens its tools (and
//  options) above it. Undo / redo sit at the end of the row.
//

import SwiftUI
import TrafficEngine

enum PaletteCategory: String, CaseIterable, Identifiable {
    case inspect, roads, homes, work, services, junctions, bulldoze
    var id: String { rawValue }

    var title: String {
        switch self {
        case .inspect: return "Inspect"
        case .roads: return "Roads"
        case .homes: return "Homes"
        case .work: return "Work"
        case .services: return "Services"
        case .junctions: return "Junctions"
        case .bulldoze: return "Bulldoze"
        }
    }

    var symbol: String {
        switch self {
        case .inspect: return "hand.point.up.left.fill"
        case .roads: return "road.lanes"
        case .homes: return "house.fill"
        case .work: return "building.2.fill"
        case .services: return "shield.lefthalf.filled"
        case .junctions: return "arrow.triangle.branch"
        case .bulldoze: return "xmark.bin.fill"
        }
    }

    var tools: [BuildTool] {
        switch self {
        case .inspect: return [.inspect]
        case .roads: return [.drawRoad, .restyleRoad, .pockets]
        case .homes: return [.building(.house), .building(.townhouse), .building(.apartment)]
        case .work: return [.building(.shop), .building(.office), .building(.factory)]
        case .services: return [.building(.policeStation), .building(.school), .building(.hospital), .building(.fireStation)]
        case .junctions: return [.control(.auto), .control(.signal), .control(.allWayStop), .control(.twoWayStop),
                                 .control(.yield), .control(.roundabout), .moveJunction]
        case .bulldoze: return [.bulldoze]
        }
    }

    static func of(_ t: BuildTool) -> PaletteCategory {
        allCases.first { $0.tools.contains(t) } ?? .inspect
    }
}

struct BuildPalette: View {
    @ObservedObject var game: GameController
    @State private var open: PaletteCategory?

    var body: some View {
        VStack(spacing: 8) {
            if let open {
                fitting(toolRow(open))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            fitting(categoryRow)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: open)
    }

    /// Scrolls sideways only when the row doesn't fit (portrait iPhone).
    private func fitting<V: View>(_ v: V) -> some View {
        ViewThatFits(in: .horizontal) {
            v
            ScrollView(.horizontal, showsIndicators: false) { v }
        }
    }

    private var categoryRow: some View {
        HStack(spacing: 2) {
            ForEach(PaletteCategory.allCases) { c in
                Button {
                    if c.tools.count == 1 {
                        game.tool = c.tools[0]
                        open = nil
                    } else if open == c {
                        open = nil
                    } else {
                        open = c
                        if !c.tools.contains(game.tool) { game.tool = c.tools[0] }
                    }
                } label: {
                    PaletteIcon(symbol: c.symbol, active: PaletteCategory.of(game.tool) == c)
                }
                .accessibilityIdentifier("palette.\(c.rawValue)")
                .accessibilityLabel(c.title)
                .accessibilityAddTraits(PaletteCategory.of(game.tool) == c ? .isSelected : [])
            }
            Divider().frame(height: 28).padding(.horizontal, 4)
            Button { game.undo() } label: { PaletteIcon(symbol: "arrow.uturn.backward", active: false) }
                .disabled(!game.canUndo)
                .opacity(game.canUndo ? 1 : 0.35)
                .accessibilityIdentifier("tool.undo")
                .accessibilityLabel("Undo")
            Button { game.redo() } label: { PaletteIcon(symbol: "arrow.uturn.forward", active: false) }
                .disabled(!game.canRedo)
                .opacity(game.canRedo ? 1 : 0.35)
                .accessibilityIdentifier("tool.redo")
                .accessibilityLabel("Redo")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .floatingSurface()
    }

    private func toolRow(_ c: PaletteCategory) -> some View {
        HStack(spacing: 2) {
            ForEach(c.tools, id: \.self) { t in
                Button { game.tool = t } label: {
                    PaletteIcon(symbol: t.symbol, active: game.tool == t, small: true)
                }
                .accessibilityIdentifier(t.identifier)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(game.tool == t ? .isSelected : [])
            }
            if c == .roads {
                Divider().frame(height: 24).padding(.horizontal, 4)
                RoadOptionsControls(options: $game.roadOptions)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .floatingSurface(radius: Metrics.radiusSmall)
    }
}

struct RoadOptionsControls: View {
    @Binding var options: RoadOptions

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Road type", selection: $options.roadClass) {
                    ForEach(RoadOptions.classes, id: \.self) { Text($0.paletteName).tag($0) }
                }
            } label: {
                Text(options.roadClass.paletteName)
                    .font(.hud(13))
                    .padding(.horizontal, 8).frame(height: 32)
                    .background(Capsule().fill(Theme.color(.land)))
            }
            .accessibilityIdentifier("road.class")
            .accessibilityLabel("Road type")
            .accessibilityValue(options.roadClass.paletteName)
            Button {
                options.lanes = options.lanes % 3 + 1
            } label: {
                Text("\(options.lanes)×")
                    .font(.hud(13))
                    .frame(width: 34, height: 32)
                    .background(Capsule().fill(Theme.color(.land)))
            }
            .accessibilityIdentifier("road.lanes")
            .accessibilityLabel("Lanes each way")
            .accessibilityValue("\(options.lanes)")
            Button {
                options.oneWay.toggle()
            } label: {
                Image(systemName: options.oneWay ? "arrow.right" : "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 32)
                    .background(Capsule().fill(options.oneWay ? Theme.color(.uiAccent).opacity(0.25) : Theme.color(.land)))
            }
            .accessibilityIdentifier("road.oneway")
            .accessibilityLabel(options.oneWay ? "One way" : "Two way")
        }
        .foregroundStyle(Theme.color(.uiInk))
    }
}

struct PaletteIcon: View {
    let symbol: String
    let active: Bool
    var small = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: small ? 16 : 18, weight: .bold))
            .foregroundStyle(active ? Color.white : Theme.color(.uiInk))
            .frame(width: small ? 38 : 40, height: small ? 38 : 40)
            .background(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                .fill(active ? Theme.color(.uiAccent) : Color.clear))
            .contentShape(Rectangle())
    }
}

/// Transient message after an edit.
struct FeedbackToast: View {
    let feedback: EditFeedback

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(feedback.ok ? Theme.color(.signalGreen) : Theme.color(.signalRed))
            Text(feedback.message)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.color(.uiInk))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .floatingSurface(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback.toast")
    }
}
