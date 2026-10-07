//
//  CityScene+Input.swift
//  TrafficSimulator
//
//  Camera and touch input, the way a maps app behaves:
//   • pinch zooms around the fingers (the point under them stays put), and
//     moving the fingers while pinching pans at the same time
//   • drag to pan (two fingers while a drawing tool is active); a flick glides
//     on and slows down
//   • double tap zooms in on that spot, two-finger tap zooms out
//   • the view stays over the map, from the whole region down to street level
//  Plus one-finger drawing for the road and move tools, and the ghost that
//  flashes an edit's outcome.
//

import SpriteKit
import UIKit
import TrafficEngine

/// An animated camera move (eased).
struct CameraAnimation {
    var from: CGPoint
    var to: CGPoint
    var fromScale: CGFloat
    var toScale: CGFloat
    var elapsed: Double = 0
    var duration: Double
}

extension CityScene: UIGestureRecognizerDelegate {

    /// Closest zoom: a car is about 110 points long.
    var minCamScale: CGFloat { 0.035 }

    /// Farthest zoom: the whole region (map plus its surroundings) in view.
    var maxCamScale: CGFloat {
        let viewSize = view?.bounds.size ?? CGSize(width: 844, height: 390)
        let w = (worldBounds.max.x - worldBounds.min.x) + 2 * Self.outskirts
        let h = (worldBounds.max.y - worldBounds.min.y) + 2 * Self.outskirts
        return max(0.5, min(CGFloat(w) / max(viewSize.width, 1), CGFloat(h) / max(viewSize.height, 1)))
    }

    /// How far the countryside extends beyond the map [m].
    static let outskirts: Double = 900

    func installGestures(on view: SKView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(twoFingerTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
    }

    /// Pinch and pan run together, so a two-finger gesture can zoom and move at once.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    // MARK: Pan

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view = g.view else { return }
        if g.state == .began {
            camAnimation = nil
            panVelocity = .zero
            // One finger with a drawing tool draws; two fingers always pan.
            stroke = (controller?.tool.drags ?? false) && g.numberOfTouches == 1 ? [] : nil
        }
        if stroke != nil {
            let p = convertPoint(fromView: g.location(in: view))
            let w = Vector2(Double(p.x), Double(p.y))
            if g.state == .began {
                // Start where the finger first touched, not where the pan was recognised.
                let t = g.translation(in: view)
                let s0 = convertPoint(fromView: CGPoint(x: g.location(in: view).x - t.x, y: g.location(in: view).y - t.y))
                stroke = [Vector2(Double(s0.x), Double(s0.y))]
            }
            if let last = stroke?.last, last.distance(to: w) >= 2.5 { stroke?.append(w) }
            updateStrokeNode()
            if g.state == .ended || g.state == .cancelled || g.state == .failed {
                let pts = stroke ?? []
                stroke = nil
                strokeNode?.removeFromParent()
                strokeNode = nil
                if g.state == .ended, pts.count >= 2 { onDraw?(pts + [w], Double(max(4, 22 * camScale))) }
            }
            return
        }
        // While pinching, the pinch moves the camera (it keeps the point under
        // the fingers fixed), so the pan just tracks.
        let t = g.translation(in: view)
        g.setTranslation(.zero, in: view)
        guard pinchAnchor == nil else { return }
        cam.position = CGPoint(x: cam.position.x - t.x * camScale, y: cam.position.y + t.y * camScale)
        clampCamera()
        if g.state == .ended {
            let v = g.velocity(in: view)
            // Only a real flick glides.
            panVelocity = hypot(v.x, v.y) > 120 ? v : .zero
        }
    }

    // MARK: Pinch

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let view = g.view else { return }
        let loc = g.location(in: view)
        switch g.state {
        case .began:
            camAnimation = nil
            panVelocity = .zero
            pinchStart = camScale
            pinchAnchor = convertPoint(fromView: loc)
        case .changed:
            guard let anchor = pinchAnchor else { return }
            setCamScale(pinchStart / max(g.scale, 0.01))
            // Keep the anchor under the fingers (this also pans with them).
            let now = convertPoint(fromView: loc)
            cam.position = CGPoint(x: cam.position.x + anchor.x - now.x, y: cam.position.y + anchor.y - now.y)
            clampCamera()
        default:
            pinchAnchor = nil
        }
    }

    // MARK: Taps

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let view = g.view else { return }
        panVelocity = .zero
        let p = convertPoint(fromView: g.location(in: view))
        onTap?(Vector2(Double(p.x), Double(p.y)), Double(max(4, 22 * camScale)))
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = g.view else { return }
        zoom(by: 0.45, around: g.location(in: view))
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let view = g.view else { return }
        zoom(by: 2.2, around: g.location(in: view))
    }

    /// Zoom by a factor, keeping the point under `viewPoint` where it is.
    func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        let anchor = convertPoint(fromView: viewPoint)
        let target = (camScale * factor).clamped(minCamScale, maxCamScale)
        let k = target / camScale
        // The camera moves towards the anchor in proportion to the zoom.
        let to = CGPoint(x: anchor.x + (cam.position.x - anchor.x) * k, y: anchor.y + (cam.position.y - anchor.y) * k)
        animateCamera(to: to, scale: target)
    }

    // MARK: Camera

    func setCamScale(_ s: CGFloat) {
        camScale = s.clamped(minCamScale, maxCamScale)
        cam.setScale(camScale)
    }

    /// Keep the view over the map and its surroundings.
    func clampCamera() {
        let m = Self.outskirts * 0.8
        let x = Double(cam.position.x).clamped(to: (worldBounds.min.x - m)...(worldBounds.max.x + m))
        let y = Double(cam.position.y).clamped(to: (worldBounds.min.y - m)...(worldBounds.max.y + m))
        cam.position = CGPoint(x: x, y: y)
    }

    func animateCamera(to p: CGPoint, scale: CGFloat, duration: Double = 0.35) {
        panVelocity = .zero
        if reduceMotion {
            cam.position = p
            setCamScale(scale)
            clampCamera()
            return
        }
        camAnimation = CameraAnimation(from: cam.position, to: p, fromScale: camScale, toScale: scale, duration: duration)
    }

    /// Per frame: glide after a flick, or run a camera animation.
    func stepCamera(dt: Double) {
        guard dt > 0 else { return }
        if var a = camAnimation {
            a.elapsed += dt
            let u = min(a.elapsed / a.duration, 1)
            let e = CGFloat(u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2)    // ease in-out
            setCamScale(a.fromScale + (a.toScale - a.fromScale) * e)
            cam.position = CGPoint(x: a.from.x + (a.to.x - a.from.x) * e, y: a.from.y + (a.to.y - a.from.y) * e)
            clampCamera()
            camAnimation = u >= 1 ? nil : a
            return
        }
        guard panVelocity != .zero else { return }
        cam.position = CGPoint(x: cam.position.x - panVelocity.x * camScale * CGFloat(dt),
                               y: cam.position.y + panVelocity.y * camScale * CGFloat(dt))
        clampCamera()
        // Exponential slow-down, like a scroll view.
        let k = CGFloat(exp(-dt * 4.2))
        panVelocity = CGPoint(x: panVelocity.x * k, y: panVelocity.y * k)
        if hypot(panVelocity.x, panVelocity.y) < 8 { panVelocity = .zero }
    }

    /// Frame the whole town (the recentre button).
    func showWholeCity() {
        guard let g = controller?.buffer.latestGeometry() else { return }
        let b = g.bounds
        let viewSize = view?.bounds.size ?? CGSize(width: 844, height: 390)
        let s = min(CGFloat(b.max.x - b.min.x) / max(viewSize.width, 1), CGFloat(b.max.y - b.min.y) / max(viewSize.height, 1)) * 1.1
        animateCamera(to: CGPoint(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2), scale: s.clamped(minCamScale, maxCamScale), duration: 0.5)
    }

    /// Zoom to a world point (UI tests and the inspector "focus" button).
    func focus(on p: Vector2, scale: CGFloat) {
        animateCamera(to: cg(p), scale: scale)
    }

    // MARK: Drawing

    func updateStrokeNode() {
        guard let pts = stroke, pts.count >= 2 else { return }
        let width = CGFloat(controller?.tool == .drawRoad ? max(6, (controller?.roadOptions.lanes ?? 1) * 7) : 3)
        let node: SKShapeNode
        if let existing = strokeNode {
            node = existing
        } else {
            node = SKShapeNode()
            node.lineCap = .round
            node.lineJoin = .round
            ghostLayer.addChild(node)
            strokeNode = node
        }
        node.path = path(pts, closed: false)
        node.strokeColor = Theme.ui(.uiAccent).withAlphaComponent(0.55)
        node.lineWidth = width
        node.fillColor = .clear
    }

    /// Flash the outcome of an edit: a ghost footprint or stroke, green when
    /// it worked, red when it didn't.
    func showFeedback(_ f: EditFeedback) {
        let color = f.ok ? Theme.ui(.signalGreen) : Theme.ui(.signalRed)
        var node: SKShapeNode?
        if f.path.count >= 2 {
            let n = SKShapeNode(path: path(f.path, closed: false))
            n.strokeColor = color.withAlphaComponent(0.7)
            n.lineWidth = 7
            n.lineCap = .round
            n.lineJoin = .round
            n.fillColor = .clear
            node = n
        } else if let at = f.at {
            let side = CGFloat(max(f.size, 8))
            let n = SKShapeNode(rectOf: CGSize(width: side, height: side), cornerRadius: 3)
            n.position = cg(at)
            n.fillColor = color.withAlphaComponent(0.35)
            n.strokeColor = color
            n.lineWidth = 1.5
            node = n
        }
        guard let n = node else { return }
        ghostLayer.addChild(n)
        let fade = SKAction.sequence([.wait(forDuration: f.ok ? 0.25 : 0.6), .fadeOut(withDuration: reduceMotion ? 0.01 : 0.35), .removeFromParent()])
        n.run(fade)
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), Swift.max(lo, hi)) }
}
