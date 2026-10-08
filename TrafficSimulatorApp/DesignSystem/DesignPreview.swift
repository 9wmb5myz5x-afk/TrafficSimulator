//
//  DesignPreview.swift
//  TrafficSimulator
//
//  Renders every colour token (day / dusk / night), building and vehicle at
//  several zooms — used (and screenshotted) to judge visual quality.
//

import SwiftUI
import SpriteKit
import TrafficEngine

struct DesignPreview: View {
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Vehicles") {
                        // Each type in three paints: the shape and the detail
                        // layer (glass, roof, cargo box, livery) carry the type.
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(VehicleClass.allCases, id: \.self) { c in
                                HStack(alignment: .center, spacing: 14) {
                                    Text(String(describing: c).capitalized)
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 52, alignment: .leading)
                                    ForEach([1, 5, 9], id: \.self) { k in
                                        vehicle(c, zoom: 9, paint: RGB(Theme.vehicleBodies[k % Theme.vehicleBodies.count]).color)
                                    }
                                }
                            }
                        }
                    }
                    section("Vehicles at map zooms") {
                        ForEach([3.0, 5.0], id: \.self) { z in
                            HStack(alignment: .center, spacing: 12) {
                                ForEach(VehicleClass.allCases, id: \.self) { c in
                                    vehicle(c, zoom: z, paint: RGB(Theme.vehicleBodies[3]).color)
                                }
                            }
                        }
                    }
                    section("Colour tokens") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(Token.allCases, id: \.self) { t in
                                HStack(spacing: 4) {
                                    ForEach([0.0, 1.0, 2.0], id: \.self) { p in
                                        RoundedRectangle(cornerRadius: 6).fill(Color(Theme.ui(t, phase: p))).frame(width: 26, height: 26)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
                                    }
                                    Text("\(String(describing: t))").font(.caption2.weight(.semibold)).lineLimit(1)
                                }
                            }
                        }
                    }
                    section("Buildings") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .bottom, spacing: 18) {
                                ForEach(BuildingKind.allCases, id: \.self) { k in
                                    VStack(spacing: 6) {
                                        building(k, scale: 3)
                                        Text(k.displayName).font(.caption2)
                                    }
                                }
                            }
                        }
                    }
                    section("Vehicle body palette") {
                        HStack(spacing: 6) {
                            ForEach(Theme.vehicleBodies, id: \.self) { hex in
                                Circle().fill(RGB(hex).color).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.black.opacity(0.1)))
                            }
                        }
                    }
                    section("Typography") {
                        Text("08:42").font(.hud(34))
                        Text("MONDAY").font(.hudLabel(12)).tracking(2).foregroundStyle(Theme.color(.uiMuted))
                        Text("RIVERSIDE").font(.hudLabel(14)).tracking(6).foregroundStyle(Theme.color(.roadEdge))
                    }
                }
                .padding(Metrics.gutter)
            }
            .background(Theme.color(.land).ignoresSafeArea())
            .navigationTitle("Design")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose).accessibilityIdentifier("design.done") } }
        }
        .accessibilityIdentifier("design.preview")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.hud(16)).foregroundStyle(Theme.color(.uiInk))
            content()
        }
    }

    private func image(_ t: SKTexture) -> Image { Image(uiImage: UIImage(cgImage: t.cgImage())) }

    private func building(_ k: BuildingKind, scale: CGFloat) -> some View {
        let w = CGFloat(k.size.width) * scale, d = CGFloat(k.size.depth) * scale
        let h = CGFloat(k.size.height)
        return ZStack {
            RoundedRectangle(cornerRadius: min(w, d) * 0.14).fill(Color(Theme.ui(.shadow)).opacity(0.14))
                .frame(width: w, height: d).offset(x: (1.2 + h * 1.1) * scale, y: (1.2 + h * 1.1) * scale)
            RoundedRectangle(cornerRadius: min(w, d) * 0.14).fill(Color(Theme.ui(k.tokens.side)))
                .frame(width: w, height: d).offset(x: 0.5 * scale, y: (0.9 + h * 0.25) * scale)
            image(Textures.roof(k)).resizable().frame(width: w, height: d)
        }
        .padding(.trailing, (1.2 + h * 1.1) * scale)
        .padding(.bottom, (1.2 + h * 1.1) * scale)
    }

    /// As on the map: shadow, body tinted with the paint (police untinted),
    /// then the untinted detail layer.
    private func vehicle(_ c: VehicleClass, zoom: CGFloat, paint: Color) -> some View {
        ZStack {
            image(Textures.vehicleShape(c)).resizable()
                .colorMultiply(.black).opacity(0.18)
                .offset(x: 0.35 * zoom, y: 0.35 * zoom)
            image(Textures.vehicle(c)).resizable()
                .colorMultiply(c == .police ? .white : c == .bus ? Theme.color(.uiAccent) : paint)
            image(Textures.vehicleTop(c)).resizable()
        }
        .frame(width: CGFloat(c.length) * zoom, height: CGFloat(c.width) * zoom)
    }
}
