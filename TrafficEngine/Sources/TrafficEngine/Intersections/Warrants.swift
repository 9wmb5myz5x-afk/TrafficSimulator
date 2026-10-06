//
//  Warrants.swift
//  TrafficEngine
//
//  Automatic junction control, simplified from the MUTCD warrants:
//
//   • by road class when a junction is built (see NetworkBuilder.classWarrant)
//   • by measured volume, re-evaluated once per simulated day:
//       – all-way stop: peak-hour entering volume ≥ 300 veh/h with the minor
//         street ≥ 100 veh/h (MUTCD 2B.07, peak-hour form)
//       – signal: major street ≥ 600 veh/h and minor street ≥ 150 veh/h in the
//         same peak hour (MUTCD 4C "peak hour" warrant, simplified)
//  Upgrades are applied automatically when `autoTrafficControl` is on and the
//  junction is not locked; otherwise they are recorded as suggestions.
//

public struct ControlSuggestion: Codable, Sendable, Equatable {
    public var node: NodeID
    public var current: ControlType
    public var suggested: ControlType
    public var peakMajor: Double
    public var peakMinor: Double
}

public struct WarrantState: Codable, Sendable, Equatable {
    /// Entries per (node, approach edge) in the current window.
    var windowCounts: [Int: [Int: Int]] = [:]
    /// Longest wait at a stop / yield line per node in the current window [s].
    var windowMaxWait: [Int: Double] = [:]
    var windowStart: Double = 0
    public var suggestions: [ControlSuggestion] = []
}

extension ControlType {
    /// Strength of control, for "upgrade only" comparisons.
    var strength: Int {
        switch self {
        case .auto, .uncontrolled: return 0
        case .yield: return 1
        case .twoWayStop: return 2
        case .allWayStop: return 3
        case .roundabout: return 4
        case .signal: return 5
        }
    }
}

extension Simulation {

    func recordEntryForWarrants(node: NodeID, approach: EdgeID) {
        warrants.windowCounts[node.raw, default: [:]][approach.raw, default: 0] += 1
    }

    func recordLineWaitForWarrants(node: NodeID, wait: Double) {
        if wait > warrants.windowMaxWait[node.raw] ?? 0 { warrants.windowMaxWait[node.raw] = wait }
    }

    /// Every 5 simulated minutes (≈ 40 clock minutes), review each automatic junction against the
    /// window's flows (veh/h of simulated, physical time):
    ///  • signal: major ≥ 600 and minor ≥ 150 (peak-hour volume warrant), or
    ///    a side-road driver waited ≥ 90 s while the major street carried
    ///    ≥ 400 veh/h (MUTCD Warrant 3A, delay form)
    ///  • all-way stop: total ≥ 300 with minor ≥ 100 and major < 500
    /// Upgrades only; applied at once when auto traffic control is on.
    func updateWarrants() {
        // Every 5 minutes, or after 2 when a side-road driver has already
        // waited 2 minutes (don't let a starving approach wait for the review).
        let elapsed = time - warrants.windowStart
        let urgent = warrants.windowMaxWait.values.contains { $0 >= 120 }
        guard elapsed >= 300 || (urgent && elapsed >= 120) else { return }
        let window = elapsed
        var changed = false
        for n in network.allNodes where n.control.requested == .auto && network.degree(of: n.id) >= 3 && !n.isRegionalConnection {
            let approaches = warrants.windowCounts[n.id.raw] ?? [:]
            var major = 0.0, minor = 0.0
            for (e, c) in approaches {
                let rate = Double(c) * 3600 / window
                if network.isMajorApproach(EdgeID(e), at: n.id) { major += rate } else { minor = max(minor, rate) }
            }
            let maxWait = warrants.windowMaxWait[n.id.raw] ?? 0
            let current = n.effectiveControl
            var target = current
            if (major >= 600 && minor >= 150) || (maxWait >= 90 && major >= 400 && current != .allWayStop && current != .roundabout) {
                target = .signal
            } else if major + minor >= 300 && minor >= 100 && major < 500 && current.strength < ControlType.allWayStop.strength {
                // All-way stop only for balanced, moderate volumes (it cuts major-street capacity).
                target = .allWayStop
            }
            guard target.strength > current.strength else { continue }
            if config.autoTrafficControl && !n.control.locked {
                network.updateNode(n.id) { $0.warrantControl = target }
                changed = true
                log(.controlUpgraded, "\(n.id): \(current.rawValue) → \(target.rawValue) (major \(Int(major)) / minor \(Int(minor)) veh/h, longest wait \(Int(maxWait)) s)")
            } else if !warrants.suggestions.contains(where: { $0.node == n.id && $0.suggested == target }) {
                warrants.suggestions.append(ControlSuggestion(node: n.id, current: current, suggested: target,
                                                              peakMajor: major, peakMinor: minor))
                log(.controlSuggested, "\(n.id): suggest \(target.rawValue)")
            }
        }
        warrants.windowCounts = [:]
        warrants.windowMaxWait = [:]
        warrants.windowStart = time
        if changed { networkDidChange() }
    }
}
