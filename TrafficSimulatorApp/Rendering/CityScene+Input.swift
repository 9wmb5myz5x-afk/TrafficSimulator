//
//  CityScene+Input.swift
//  TrafficSimulator
//
//  Camera gestures (pan, pinch), taps, one-finger drawing for the road and
//  move tools, and the ghost that flashes an edit's outcome.
//

import SpriteKit
import UIKit
import TrafficEngine

extension CityScene {

    func installGestures(on view: SKView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view = g.view else { return }
        if g.state == .began {
            panStart = cam.position
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
        let t = g.translation(in: view)
        var p = CGPoint(x: panStart.x - t.x * camScale, y: panStart.y + t.y * camScale)
        p.x = min(max(p.x, worldBounds.min.x - 200), worldBounds.max.x + 200)
        p.y = min(max(p.y, worldBounds.min.y - 200), worldBounds.max.y + 200)
        cam.position = p
    }

    private func updateStrokeNode() {
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

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { pinchStart = camScale }
        camScale = min(max(pinchStart / max(g.scale, 0.01), 0.04), 8)
        cam.setScale(camScale)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let view = g.view else { return }
        let p = convertPoint(fromView: g.location(in: view))
        onTap?(Vector2(Double(p.x), Double(p.y)), Double(max(4, 22 * camScale)))
    }

    /// Zoom to a world point (UI tests and the inspector "focus" button).
    func focus(on p: Vector2, scale: CGFloat) {
        let move = SKAction.move(to: cg(p), duration: reduceMotion ? 0 : 0.4)
        move.timingMode = .easeInEaseOut
        cam.run(move)
        camScale = scale
        let zoom = SKAction.scale(to: scale, duration: reduceMotion ? 0 : 0.4)
        zoom.timingMode = .easeInEaseOut
        cam.run(zoom)
    }
}
