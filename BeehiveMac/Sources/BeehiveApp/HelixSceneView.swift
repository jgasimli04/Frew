import AppKit
import BeehiveKit
import SceneKit
import SwiftUI

/// Shared scaling from helix coordinates -> scene units. The cursor marker MUST
/// use the exact same math as the line vertices, or it drifts off the curve.
private struct HelixScaling {
    var rScale = 5.0
    var zScale = 22.0
    var hmax = 1.0
    func point(x: Double, y: Double, h: Double) -> SCNVector3 {
        SCNVector3(x * rScale, y * rScale, (h / hmax) * zScale - zScale / 2)
    }
}

/// The song as a 3D helix: rotation = tempo, climb = energy spent, colour =
/// timbre (chroma hue). Drag to orbit/zoom; the glowing bead is the playhead.
struct HelixSceneView: NSViewRepresentable {
    let record: HelixRecord
    var cursor: Double            // fractional frame — the bead glides between vertices
    var autoSpin: Bool
    var camera: CameraCommand
    var env: BandEnvelopes?       // live 5-band energy — makes the coil breathe

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true            // free orbit + scroll/pinch zoom
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        // render at the panel's full rate — 120 Hz on ProMotion displays
        v.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120
        let c = context.coordinator
        c.scene.background.contents = NSColor.black
        v.scene = c.scene
        v.pointOfView = c.cameraNode
        c.scene.rootNode.addChildNode(c.cameraNode)
        v.defaultCameraController.target = SCNVector3Zero
        c.rebuild(record: record)
        c.applySpin(autoSpin)
        c.moveMarker(to: cursor, record: record)
        c.applyAudio(cursor: cursor, env: env)
        c.apply(camera: camera, animated: false)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        if c.songId != record.meta.songId { c.rebuild(record: record) }
        c.applySpin(autoSpin)
        c.moveMarker(to: cursor, record: record)
        c.applyAudio(cursor: cursor, env: env)
        c.apply(camera: camera, animated: true)
    }

    // MARK: - Coordinator: owns the scene so SwiftUI ticks don't rebuild the mesh

    final class Coordinator {
        let scene = SCNScene()
        let helixNode = SCNNode()     // geometry + marker live here; this is what spins
        let markerNode = SCNNode()
        let cameraNode = SCNNode()
        var songId = ""
        var lastCameraNonce = -1
        private var scaling = HelixScaling()

        init() {
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zFar = 500
            // HDR bloom: the strands glow into the surrounding black on the highs
            cameraNode.camera?.wantsHDR = true
            cameraNode.camera?.bloomThreshold = 0.4
            cameraNode.camera?.bloomBlurRadius = 12
            cameraNode.camera?.bloomIntensity = 0.2
            cameraNode.position = SCNVector3(24, -22, 22)

            let sphere = SCNSphere(radius: 0.42)
            sphere.segmentCount = 16
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColor.white
            m.emission.contents = NSColor.white
            m.readsFromDepthBuffer = false        // bead stays visible through the coils
            sphere.materials = [m]
            markerNode.geometry = sphere
            markerNode.renderingOrder = 10
        }

        func rebuild(record r: HelixRecord) {
            songId = r.meta.songId
            helixNode.geometry = nil
            helixNode.childNodes.forEach { $0.removeFromParentNode() }
            if helixNode.parent == nil { scene.rootNode.addChildNode(helixNode) }

            let n = r.nFrames
            guard n > 1 else { return }
            scaling.hmax = max(r.h.last ?? 1, 1e-6)
            let step = max(1, n / 2600)

            var verts: [SCNVector3] = []
            var colors: [SIMD4<Float>] = []
            var indices: [Int32] = []
            var c = 0
            for i in stride(from: 0, to: n, by: step) {
                verts.append(scaling.point(x: r.x[i], y: r.y[i], h: r.h[i]))
                colors.append(hsv(h: r.hue[i],
                                  s: 0.45 + 0.55 * r.sat[i],
                                  v: 0.40 + 0.60 * r.val[i]))
                if c > 0 { indices.append(Int32(c - 1)); indices.append(Int32(c)) }
                c += 1
            }

            let vSource = SCNGeometrySource(vertices: verts)
            let colorData = colors.withUnsafeBytes { Data($0) }
            let cSource = SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: colors.count,
                usesFloatComponents: true, componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geo = SCNGeometry(sources: [vSource, cSource], elements: [element])
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            geo.materials = [mat]
            helixNode.geometry = geo

            // marker rides the SAME node, so the auto-spin carries it along the curve
            helixNode.addChildNode(markerNode)
        }

        func moveMarker(to cursor: Double, record r: HelixRecord) {
            let n = r.nFrames
            guard n > 0 else { markerNode.isHidden = true; return }
            markerNode.isHidden = false
            let f = min(max(cursor, 0), Double(n - 1))
            let i = Int(f), j = min(i + 1, n - 1)
            let u = f - Double(i)
            markerNode.position = scaling.point(x: r.x[i] + (r.x[j] - r.x[i]) * u,
                                                y: r.y[i] + (r.y[j] - r.y[i]) * u,
                                                h: r.h[i] + (r.h[j] - r.h[i]) * u)
        }

        /// Per-frame live reaction to the music, sampled at the playhead. The whole
        /// coil breathes (x/y scale) with the low bands, the strands bloom on the
        /// highs, and everything deflates + dims on the bass-departure drop. Same
        /// `inflate` shape as the 2D stage overlay (StageView) so they agree.
        func applyAudio(cursor: Double, env: BandEnvelopes?) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0        // track the frame, don't lag
            defer { SCNTransaction.commit() }

            guard let env else {                        // no analysis yet → rest state
                helixNode.scale = SCNVector3(1, 1, 1)
                cameraNode.camera?.bloomIntensity = 0.2
                helixNode.geometry?.firstMaterial?.transparency = 1
                return
            }

            let bands = env.values(at: cursor)
            let drop = CGFloat(env.drop(at: cursor))
            let sub = CGFloat(bands[0]), low = CGFloat(bands[1])
            let hiMid = CGFloat(bands[3]), hi = CGFloat(bands[4])

            let inflate = (0.78 + 0.34 * (0.45 * sub + 0.55 * low)) * (1 - 0.45 * drop)
            helixNode.scale = SCNVector3(inflate, inflate, 1)
            cameraNode.camera?.bloomIntensity = 0.2 + 2.0 * max(hi, hiMid)
            helixNode.geometry?.firstMaterial?.transparency = 1 - 0.45 * drop
        }

        func applySpin(_ on: Bool) {
            if on {
                if helixNode.action(forKey: "spin") == nil {
                    let spin = SCNAction.repeatForever(
                        .rotate(by: .pi * 2, around: SCNVector3(0, 0, 1), duration: 30))
                    helixNode.runAction(spin, forKey: "spin")   // relative: no jump on stop
                }
            } else {
                helixNode.removeAction(forKey: "spin")
            }
        }

        func apply(camera: CameraCommand, animated: Bool) {
            guard camera.nonce != lastCameraNonce else { return }
            lastCameraNonce = camera.nonce

            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.55 : 0
            switch camera.preset {
            case .top:
                cameraNode.position = SCNVector3(0, 0, 40)
                cameraNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0),
                                localFront: SCNVector3(0, 0, -1))
            case .side:
                cameraNode.position = SCNVector3(0, -40, 0)
                cameraNode.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1),
                                localFront: SCNVector3(0, 0, -1))
            case .orbit:
                cameraNode.position = SCNVector3(24, -22, 22)
                cameraNode.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1),
                                localFront: SCNVector3(0, 0, -1))
            case .zoomIn, .zoomOut:
                let f: Float = camera.preset == .zoomIn ? 0.78 : 1.28
                let p = cameraNode.position
                cameraNode.position = SCNVector3(p.x * CGFloat(f), p.y * CGFloat(f), p.z * CGFloat(f))
            }
            SCNTransaction.commit()
        }

        private func hsv(h: Float, s: Float, v: Float) -> SIMD4<Float> {
            let i = floor(h * 6)
            let f = h * 6 - i
            let p = v * (1 - s)
            let q = v * (1 - f * s)
            let t = v * (1 - (1 - f) * s)
            switch Int(i) % 6 {
            case 0: return SIMD4(v, t, p, 1)
            case 1: return SIMD4(q, v, p, 1)
            case 2: return SIMD4(p, v, t, 1)
            case 3: return SIMD4(p, q, v, 1)
            case 4: return SIMD4(t, p, v, 1)
            default: return SIMD4(v, p, q, 1)
            }
        }
    }
}
