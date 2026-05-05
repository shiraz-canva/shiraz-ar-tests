import SwiftUI
import RealityKit
import ARKit
import Vision
import simd

// MARK: - Procedural shirt mesh (XZ plane so -π/2 X-rotation makes it upright)

private func makeGridMesh(name: String,
                          width: Float, height: Float,
                          cols: Int, rows: Int,
                          curvatureDepth: Float,
                          wrinkleAmp: Float,
                          yOffset: Float = 0,
                          flipV: Bool = false) -> MeshResource? {

    var positions: [SIMD3<Float>] = []
    var normals:   [SIMD3<Float>] = []
    var uvCoords:  [SIMD2<Float>] = []
    var indices:   [UInt32]       = []

    for row in 0..<rows {
        for col in 0..<cols {
            let u  = Float(col) / Float(cols - 1)
            let v  = Float(row) / Float(rows - 1)
            let x  = (u - 0.5) * width
            let z  = (v - 0.5) * height
            let nx = (u - 0.5) * 2.0
            let curve:   Float = curvatureDepth * (1.0 - nx * nx)
            let wrinkle: Float =
                  wrinkleAmp        * sin( 5.0 * .pi * v) * (1.0 - 0.5 * nx * nx)
                + wrinkleAmp * 0.45 * sin(11.0 * .pi * v) * cos(2.5 * .pi * u)
            let y = curve + wrinkle + yOffset
            positions.append(SIMD3(x, y, z))
            uvCoords.append(SIMD2(u, flipV ? v : 1.0 - v))
        }
    }

    normals = Array(repeating: SIMD3(0, 1, 0), count: positions.count)
    for row in 1..<(rows - 1) {
        for col in 1..<(cols - 1) {
            let i  = row * cols + col
            let dz = positions[i + cols] - positions[i - cols]
            let dx = positions[i + 1]    - positions[i - 1]
            normals[i] = normalize(cross(dz, dx))
        }
    }

    for row in 0..<(rows - 1) {
        for col in 0..<(cols - 1) {
            let v0 = UInt32(row       * cols + col)
            let v1 = UInt32(row       * cols + col + 1)
            let v2 = UInt32((row + 1) * cols + col + 1)
            let v3 = UInt32((row + 1) * cols + col)
            indices += [v0, v3, v2,  v0, v2, v1]
        }
    }

    var desc = MeshDescriptor(name: name)
    desc.positions          = MeshBuffer(positions)
    desc.normals            = MeshBuffer(normals)
    desc.textureCoordinates = MeshBuffer(uvCoords)
    desc.primitives         = .triangles(indices)
    return try? MeshResource.generate(from: [desc])
}

// MARK: - ARViewContainer

struct ARViewContainer: UIViewRepresentable {

    @Binding var selectedImageURL: URL?
    @Binding var placementMode: PlacementMode
    @Binding var selectedFormat: PrintFormat
    @Binding var statusMessage: String
    @Binding var useFrontCamera: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.arView = arView
        arView.session.delegate = context.coordinator

        let coaching = ARCoachingOverlayView()
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.session  = arView.session
        coaching.goal     = .horizontalPlane
        coaching.isHidden = true   // shown only after user picks a design
        coaching.activatesAutomatically = false  // we control timing explicitly
        arView.addSubview(coaching)
        context.coordinator.coachingOverlay = coaching

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tap)
        context.coordinator.startWorldTracking()
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        let coord = context.coordinator

        let oldMode       = coord.placementMode
        let urlChanged    = coord.pendingImageURL != selectedImageURL
        let formatChanged = coord.selectedFormat.id != selectedFormat.id
        let modeChanged   = oldMode != placementMode
        let cameraChanged = coord.useFrontCamera != useFrontCamera

        if urlChanged {
            coord.cachedImage    = nil
            coord.cachedImageURL = nil
            coord.cachedTexture  = nil
        }
        coord.pendingImageURL = selectedImageURL
        coord.placementMode   = placementMode
        coord.selectedFormat  = selectedFormat
        coord.useFrontCamera  = useFrontCamera

        // Only do a full session reset when tshirt mode is involved or camera flips.
        // All other product/size changes stay in the same AR session and reformat in place.
        let involvesBodyTracking = oldMode == .tshirt || placementMode == .tshirt
        if cameraChanged || (modeChanged && involvesBodyTracking) {
            coord.switchConfiguration(for: placementMode, frontCamera: useFrontCamera)
        } else if modeChanged || formatChanged {
            coord.applyCoachingGoal()
            if !urlChanged, selectedImageURL != nil {
                // Only reformat in place if the new mode needs the same surface type as
                // the last placement. Wall→floor or floor→wall mismatches cause visible
                // artifacts (backwards billboard, missing yard-sign face), so clear and re-prompt.
                let newSurface: Coordinator.SurfaceKind = placementMode.prefersWall ? .vertical : .horizontal
                if newSurface == coord.lastPlacedSurface {
                    coord.reformatPlacedDesign()
                } else {
                    coord.arView?.scene.anchors.removeAll()
                    coord.lastPlacedTransform = nil
                    statusMessage = placementMode.placementHint
                }
            } else if !urlChanged {
                statusMessage = placementMode.placementHint
            }
        }

        // Show scan coaching only when user has a design to place but hasn't tapped yet
        coord.updateCoachingVisibility(hasDesign: selectedImageURL != nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(statusMessage: $statusMessage) }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, ARSessionDelegate {
        var arView: ARView?
        var pendingImageURL: URL?
        var placementMode: PlacementMode = .flat
        var coachingOverlay: ARCoachingOverlayView?
        var bodyAnchorEntity: AnchorEntity?
        var useFrontCamera = false

        // Format / re-placement
        var selectedFormat: PrintFormat = PrintFormat.all[0]
        var lastPlacedTransform: simd_float4x4?
        var lastPlacedSurface: SurfaceKind = .horizontal   // tracks wall vs floor/horizontal

        enum SurfaceKind { case horizontal, vertical }

        // Image / texture cache
        var cachedImageURL: URL?
        var cachedImage: UIImage?
        var cachedTexture: TextureResource?
        var isBuilding = false

        // Vision (auto-detection, secondary to tap)
        let visionQueue = DispatchQueue(label: "canvaar.vision", qos: .userInitiated)
        var frameCounter = 0

        @Binding var statusMessage: String
        init(statusMessage: Binding<String>) { _statusMessage = statusMessage }

        // MARK: - Session configuration

        func startWorldTracking() {
            guard let arView = arView else { return }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection       = [.horizontal, .vertical]
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            applyCoachingGoal()
            // Coaching overlay visibility is managed by updateCoachingVisibility — don't force-show here
            updateStatus(pendingImageURL != nil ? placementMode.placementHint : "Pick a design to start")
        }

        /// Sync the coaching overlay goal with the current placement mode.
        func applyCoachingGoal() {
            guard let overlay = coachingOverlay else { return }
            switch placementMode {
            case .frame, .canvas: overlay.goal = .verticalPlane
            default:              overlay.goal = .horizontalPlane
            }
        }

        func startBodyTracking() {
            guard let arView = arView else { return }
            arView.scene.anchors.removeAll()
            bodyAnchorEntity = nil
            isBuilding       = false
            frameCounter     = 0
            let config = ARWorldTrackingConfiguration()
            // No plane detection needed for t-shirt placement
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            coachingOverlay?.isHidden = true
            updateStatus(pendingImageURL == nil
                         ? "Pick a design first, then tap on yourself 👕"
                         : "Tap on your chest to place the shirt 👕")
        }

        func startFaceCameraTracking() {
            guard let arView = arView else { return }
            guard ARFaceTrackingConfiguration.isSupported else {
                startBodyTracking(); return
            }
            arView.scene.anchors.removeAll()
            bodyAnchorEntity = nil
            isBuilding       = false
            let config = ARFaceTrackingConfiguration()
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            coachingOverlay?.isHidden = true
            updateStatus(pendingImageURL == nil
                         ? "Pick a design first ☝️"
                         : "Look at the camera — design appears on your chest")
        }

        func switchConfiguration(for mode: PlacementMode, frontCamera: Bool = false) {
            arView?.scene.anchors.removeAll()
            bodyAnchorEntity    = nil
            isBuilding          = false
            frameCounter        = 0
            lastPlacedTransform = nil   // reset since we're restarting the session
            if mode == .tshirt {
                frontCamera ? startFaceCameraTracking() : startBodyTracking()
            } else {
                startWorldTracking()
                applyCoachingGoal()
            }
        }

        /// Shows the ARKit coaching overlay only when the user has a design ready to place
        /// but hasn't tapped a surface yet. Uses both isHidden and setActive so ARKit
        /// cannot override our intent (setActive alone can be overridden by the system).
        func updateCoachingVisibility(hasDesign: Bool) {
            let needsScan = hasDesign && lastPlacedTransform == nil && placementMode != .tshirt
            coachingOverlay?.isHidden = !needsScan
            coachingOverlay?.setActive(needsScan, animated: true)
        }

        // MARK: - ARSessionDelegate: per-frame updates

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard placementMode == .tshirt, !useFrontCamera else { return }
            frameCounter += 1

            // ── Billboard: continuously orient placed shirt to face camera ──
            if frameCounter % 4 == 0 {
                billboardShirt(cameraTransform: frame.camera.transform)
            }

            // ── Vision auto-detection (fires when no shirt placed yet) ──
            guard frameCounter % 20 == 0,
                  !isBuilding,
                  bodyAnchorEntity == nil,
                  pendingImageURL != nil else { return }

            // Gate immediately so subsequent frames don't also queue a vision request
            isBuilding = true
            let pixelBuffer  = frame.capturedImage
            let camTransform = frame.camera.transform
            let vs           = CGSize(width: UIScreen.main.bounds.width,
                                     height: UIScreen.main.bounds.height)
            visionQueue.async { [weak self] in
                self?.visionDetectAndPlace(pixelBuffer: pixelBuffer,
                                           cameraTransform: camTransform,
                                           viewSize: vs)
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            let msg = (error as NSError).code == 102
                ? "Camera access denied — enable it in Settings → Privacy & Security → Camera"
                : "AR session error: \(error.localizedDescription)"
            updateStatus(msg)
        }

        func sessionWasInterrupted(_ session: ARSession) {
            updateStatus("AR paused")
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            // Restart so plane detection resumes after e.g. phone lock
            startWorldTracking()
        }

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            for anchor in anchors {
                if let face = anchor as? ARFaceAnchor {
                    guard placementMode == .tshirt, useFrontCamera,
                          bodyAnchorEntity == nil else { return }
                    Task { await self.buildFaceChestDesign(from: face) }
                }
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                if let face = anchor as? ARFaceAnchor {
                    guard placementMode == .tshirt, useFrontCamera,
                          bodyAnchorEntity == nil,
                          pendingImageURL != nil else { return }
                    Task { await self.buildFaceChestDesign(from: face) }
                }
            }
        }

        // MARK: - Billboard (keeps shirt facing camera)

        @MainActor
        private func billboardShirt(cameraTransform: simd_float4x4) {
            guard let anchor = bodyAnchorEntity,
                  let shirt  = anchor.children.first as? ModelEntity else { return }
            let camPos   = SIMD3<Float>(cameraTransform.columns.3.x,
                                        cameraTransform.columns.3.y,
                                        cameraTransform.columns.3.z)
            let worldPos = anchor.position(relativeTo: nil)
            let diff     = camPos - worldPos
            guard length(diff) > 0.01 else { return }
            let toCamera = normalize(diff)
            let yaw      = atan2(-toCamera.x, -toCamera.z)
            let yawQ     = simd_quatf(angle: yaw,       axis: [0, 1, 0])
            let pitchQ   = simd_quatf(angle: -.pi / 2,  axis: [1, 0, 0])
            shirt.orientation = yawQ * pitchQ
        }

        // MARK: - Vision auto-detection

        nonisolated private func visionDetectAndPlace(pixelBuffer: CVPixelBuffer,
                                          cameraTransform: simd_float4x4,
                                          viewSize: CGSize) {
            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: .right,
                                                options: [:])
            guard (try? handler.perform([request])) != nil,
                  let obs = request.results?.first else { return }

            guard let ls = try? obs.recognizedPoint(.leftShoulder),
                  let rs = try? obs.recognizedPoint(.rightShoulder),
                  ls.confidence > 0.2, rs.confidence > 0.2 else { return }

            // Chest midpoint in Vision coords (origin bottom-left)
            let chestVX = Float(ls.location.x + rs.location.x) * 0.5
            let chestVY = Float(ls.location.y + rs.location.y) * 0.5 - 0.08

            // Convert to ARView screen coords (origin top-left)
            let screenPt = CGPoint(
                x: CGFloat(chestVX) * viewSize.width,
                y: (1.0 - CGFloat(chestVY)) * viewSize.height
            )

            // Depth from shoulder width (real shoulder ≈ 42 cm)
            let shoulderW = Float(abs(rs.location.x - ls.location.x))
            let depth: Float = shoulderW > 0.05
                ? max(0.5, min(3.0, 0.42 / (shoulderW * 0.89)))
                : 1.3

            Task { @MainActor [weak self] in
                guard let self,
                      let arView = self.arView,
                      self.placementMode == .tshirt,
                      !self.useFrontCamera,
                      !self.isBuilding,
                      self.bodyAnchorEntity == nil,
                      self.pendingImageURL != nil else { return }

                let worldPos = self.worldPoint(at: screenPt,
                                               depth: depth,
                                               arView: arView,
                                               cameraTransform: cameraTransform)
                await self.buildShirtAtWorldPosition(worldPos,
                                                     cameraTransform: cameraTransform)
            }
        }

        // MARK: - Tap gesture

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }
            guard pendingImageURL != nil else {
                updateStatus("Pick a design first ☝️"); return
            }

            let pt = gesture.location(in: arView)

            if placementMode == .tshirt, !useFrontCamera {
                // Tap-to-place: put the shirt right where the user tapped
                guard let frame = arView.session.currentFrame else {
                    updateStatus("Session not ready — try again"); return
                }
                let camTransform = frame.camera.transform
                let worldPos = worldPoint(at: pt,
                                          depth: 1.3,
                                          arView: arView,
                                          cameraTransform: camTransform)

                // Clear any existing shirt so it rebuilds at the new point
                arView.scene.anchors.removeAll()
                bodyAnchorEntity = nil
                isBuilding       = false
                Task { await buildShirtAtWorldPosition(worldPos, cameraTransform: camTransform) }
                return
            }

            // Pick the best plane alignment for the current mode:
            //  - Wall modes  → vertical first, then any
            //  - Floor modes (banner, billboard, yard sign) → horizontal first, then any
            //  - Everything else → any
            let preferHorizontal = placementMode.prefersFloor || selectedFormat.id == "yard_sign"
            let firstAlignment: ARRaycastQuery.TargetAlignment =
                placementMode.prefersWall ? .vertical : (preferHorizontal ? .horizontal : .any)
            var results = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: firstAlignment)
            if results.isEmpty {
                results = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .any)
            }
            guard let hit = results.first else {
                updateStatus("No surface found — move closer and scan slowly")
                return
            }
            Task { await placeDesign(at: hit.worldTransform, in: arView) }
        }

        // MARK: - World-point helper (ray cast, fallback to camera forward)

        @MainActor
        private func worldPoint(at screenPt: CGPoint,
                                 depth: Float,
                                 arView: ARView,
                                 cameraTransform: simd_float4x4) -> SIMD3<Float> {
            if let ray = arView.ray(through: screenPt) {
                return ray.origin + ray.direction * depth
            }
            // Fallback: depth along camera's -Z axis
            let camPos = SIMD3<Float>(cameraTransform.columns.3.x,
                                      cameraTransform.columns.3.y,
                                      cameraTransform.columns.3.z)
            let fwd = -SIMD3<Float>(cameraTransform.columns.2.x,
                                     cameraTransform.columns.2.y,
                                     cameraTransform.columns.2.z)
            return camPos + fwd * depth
        }

        // MARK: - Image loading (cached)

        @MainActor
        private func loadDesignImage() async throws -> UIImage {
            guard let url = pendingImageURL else { throw URLError(.badURL) }
            if let cached = cachedImage, cachedImageURL == url { return cached }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            cachedImage    = img
            cachedImageURL = url
            return img
        }

        // MARK: - Build shirt (back camera, world-anchored)

        @MainActor
        func buildShirtAtWorldPosition(_ worldPos: SIMD3<Float>,
                                        cameraTransform: simd_float4x4) async {
            guard let arView = arView, pendingImageURL != nil else {
                updateStatus("Pick a design first ☝️"); return
            }
            guard !isBuilding else { return }
            isBuilding = true
            updateStatus("Placing shirt…")

            do {
                let uiImage = try await loadDesignImage()
                guard let cgImage = uiImage.cgImage else { throw URLError(.cannotDecodeContentData) }

                let texture = try await TextureResource(image: cgImage,
                                                         options: .init(semantic: .color))
                let aspect  = Float(uiImage.size.width / uiImage.size.height)

                // — White shirt body —
                let shirtMesh = makeGridMesh(name: "shirt_body",
                                             width: 0.37, height: 0.47,
                                             cols: 28, rows: 36,
                                             curvatureDepth: 0.040,
                                             wrinkleAmp: 0.007)
                              ?? MeshResource.generatePlane(width: 0.37, depth: 0.47)

                var fabricMat = PhysicallyBasedMaterial()
                fabricMat.baseColor = .init(tint: .white)
                fabricMat.roughness = .init(floatLiteral: 0.92)
                fabricMat.metallic  = .init(floatLiteral: 0.0)
                let shirtEntity = ModelEntity(mesh: shirtMesh, materials: [fabricMat])

                // — Design print panel (upper chest) —
                let maxSide: Float = 0.20
                let pw: Float = aspect >= 1 ? maxSide : maxSide * aspect
                let ph: Float = aspect >= 1 ? maxSide / aspect : maxSide

                let printMesh = makeGridMesh(name: "chest_print",
                                             width: pw, height: ph,
                                             cols: 16, rows: 20,
                                             curvatureDepth: 0.041,
                                             wrinkleAmp: 0.007,
                                             yOffset: 0.003)
                              ?? MeshResource.generatePlane(width: pw, depth: ph)

                // UnlitMaterial: texture always fully visible regardless of lighting
                var printMat = UnlitMaterial()
                printMat.color = .init(texture: .init(texture))
                let printEntity = ModelEntity(mesh: printMesh, materials: [printMat])
                // shirt local-Z = world UP (after -π/2 X pitch), so +0.06 = 6 cm toward head
                printEntity.position = [0, 0, 0.06]
                shirtEntity.addChild(printEntity)

                // — Orient shirt to face camera —
                let camPos   = SIMD3<Float>(cameraTransform.columns.3.x,
                                             cameraTransform.columns.3.y,
                                             cameraTransform.columns.3.z)
                let diff     = camPos - worldPos
                let toCamera = length(diff) > 0.01 ? normalize(diff) : SIMD3<Float>(0, 0, -1)
                let yaw      = atan2(-toCamera.x, -toCamera.z)
                let yawQ     = simd_quatf(angle: yaw,      axis: [0, 1, 0])
                let pitchQ   = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
                shirtEntity.orientation = yawQ * pitchQ

                // — Anchor into scene —
                let anchor = AnchorEntity(world: worldPos)
                anchor.addChild(shirtEntity)
                arView.scene.addAnchor(anchor)
                bodyAnchorEntity = anchor
                updateStatus("Looking good! Tap to reposition 🙌")

            } catch {
                updateStatus("Couldn't load design: \(error.localizedDescription)")
            }

            isBuilding = false
        }

        // MARK: - Build design on chest (front camera / face tracking)

        @MainActor
        func buildFaceChestDesign(from faceAnchor: ARFaceAnchor) async {
            guard let arView = arView, pendingImageURL != nil else {
                updateStatus("Pick a design first ☝️"); return
            }
            guard bodyAnchorEntity == nil, !isBuilding else { return }
            isBuilding = true
            updateStatus("Placing on chest…")

            do {
                let uiImage = try await loadDesignImage()
                guard let cgImage = uiImage.cgImage else { throw URLError(.cannotDecodeContentData) }

                let texture = try await TextureResource(image: cgImage,
                                                         options: .init(semantic: .color))
                let aspect  = Float(uiImage.size.width / uiImage.size.height)

                // flipV: true because front camera uses +π/2 pitch (inverts V relative to back camera)
                let shirtMesh = makeGridMesh(name: "shirt_body",
                                             width: 0.37, height: 0.47,
                                             cols: 28, rows: 36,
                                             curvatureDepth: 0.040,
                                             wrinkleAmp: 0.007,
                                             flipV: true)
                              ?? MeshResource.generatePlane(width: 0.37, depth: 0.47)

                var fabricMat = PhysicallyBasedMaterial()
                fabricMat.baseColor = .init(tint: .white)
                fabricMat.roughness = .init(floatLiteral: 0.92)
                fabricMat.metallic  = .init(floatLiteral: 0.0)
                let shirtEntity = ModelEntity(mesh: shirtMesh, materials: [fabricMat])

                let maxSide: Float = 0.20
                let pw: Float = aspect >= 1 ? maxSide : maxSide * aspect
                let ph: Float = aspect >= 1 ? maxSide / aspect : maxSide

                let printMesh = makeGridMesh(name: "chest_print",
                                             width: pw, height: ph,
                                             cols: 16, rows: 20,
                                             curvatureDepth: 0.041,
                                             wrinkleAmp: 0.007,
                                             yOffset: 0.003,
                                             flipV: true)
                              ?? MeshResource.generatePlane(width: pw, depth: ph)

                var printMat = UnlitMaterial()
                printMat.color = .init(texture: .init(texture))
                let printEntity = ModelEntity(mesh: printMesh, materials: [printMat])
                // With +π/2 pitch, shirt local-Z = face-anchor -Y (downward).
                // So -0.06 in local-Z = +0.06 in face-anchor Y = 6 cm toward head from shirt center.
                printEntity.position = [0, 0, -0.06]
                shirtEntity.addChild(printEntity)

                // Place ~50 cm below face anchor, 5 cm toward camera.
                // +π/2 (not -π/2): mesh normal [0,1,0] → face-anchor +Z (toward camera). ✓
                shirtEntity.position    = [0, -0.50, 0.05]
                shirtEntity.orientation = simd_quatf(angle: +.pi / 2, axis: [1, 0, 0])

                let anchor = AnchorEntity(anchor: faceAnchor)
                anchor.addChild(shirtEntity)
                arView.scene.addAnchor(anchor)
                bodyAnchorEntity = anchor
                updateStatus("Looking good! Move around to see it live")

            } catch {
                updateStatus("Couldn't load design: \(error.localizedDescription)")
            }

            isBuilding = false
        }

        // MARK: - Flat / Mug / Phone-case placement

        // MARK: - Image downsampling

        /// Downsamples a UIImage so neither dimension exceeds maxSide.
        /// Returns the original if it's already small enough.
        private func downsampledImage(_ image: UIImage, maxSide: CGFloat = 1024) -> UIImage {
            let size = image.size
            let longest = max(size.width, size.height)
            guard longest > maxSide else { return image }
            let scale = maxSide / longest
            let newSize = CGSize(width: (size.width * scale).rounded(),
                                 height: (size.height * scale).rounded())
            let renderer = UIGraphicsImageRenderer(size: newSize)
            return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }

        @MainActor
        func placeDesign(at transform: simd_float4x4, in arView: ARView) async {
            guard let imageURL = pendingImageURL else { return }
            lastPlacedTransform = transform
            lastPlacedSurface   = placementMode.prefersWall ? .vertical : .horizontal
            arView.scene.anchors.removeAll()

            do {
                // Reuse cached texture when possible (format switch or re-tap same design)
                let uiImage: UIImage
                let texture: TextureResource

                if let img = cachedImage, cachedImageURL == imageURL, let tex = cachedTexture {
                    uiImage = img
                    texture = tex
                } else {
                    updateStatus("Fetching image…")
                    let (data, _) = try await URLSession.shared.data(from: imageURL)
                    guard let raw = UIImage(data: data) else {
                        updateStatus("Couldn't load image"); return
                    }
                    let small = downsampledImage(raw)         // ≤1024px — fast texture upload
                    guard let cgImage = small.cgImage else {
                        updateStatus("Couldn't load image"); return
                    }
                    texture = try await TextureResource(image: cgImage,
                                                        options: .init(semantic: .color))
                    uiImage        = small
                    cachedImage    = small
                    cachedImageURL = imageURL
                    cachedTexture  = texture
                }

                try placeWithCurrentFormat(texture: texture, image: uiImage,
                                           at: transform, in: arView)
                updateStatus("Tap again to reposition")
            } catch {
                updateStatus("Error: \(error.localizedDescription)")
            }
        }

        /// Re-places the design at the last stored transform using new format dimensions.
        /// Uses the cached texture — no async needed, instant resize.
        @MainActor
        func reformatPlacedDesign() {
            guard let transform = lastPlacedTransform,
                  let arView   = arView,
                  let image    = cachedImage,
                  let texture  = cachedTexture else { return }
            arView.scene.anchors.removeAll()
            updateStatus("Resizing to \(selectedFormat.name)…")
            do {
                try placeWithCurrentFormat(texture: texture, image: image,
                                           at: transform, in: arView)
                updateStatus("\(selectedFormat.name) — \(selectedFormat.displayDimensions)")
            } catch {
                updateStatus("Resize failed: \(error.localizedDescription)")
            }
        }

        private func placeWithCurrentFormat(texture: TextureResource, image: UIImage,
                                             at transform: simd_float4x4, in arView: ARView) throws {
            let fw = selectedFormat.widthM
            let fh = selectedFormat.heightM
            switch placementMode {
            case .flat:
                if selectedFormat.id == "yard_sign" {
                    try placeYardSignMockup(texture: texture, image: image,
                                            at: transform, in: arView, w: fw, h: fh)
                } else {
                    try placeFlatDesign(texture: texture, image: image,
                                        at: transform, in: arView, w: fw, h: fh)
                }
            case .mug:       try placeMugMockup(texture: texture, at: transform, in: arView)
            case .tshirt:    break
            case .phoneCase: try placePhoneCaseMockup(texture: texture, at: transform, in: arView)
            case .frame:     try placeFrameDesign(texture: texture, image: image,
                                                   at: transform, in: arView, w: fw, h: fh)
            case .canvas:    try placeCanvasDesign(texture: texture, image: image,
                                                    at: transform, in: arView, w: fw, h: fh)
            case .banner:    try placeBannerMockup(texture: texture, image: image,
                                                    at: transform, in: arView, w: fw, h: fh)
            case .billboard: try placeBillboardMockup(texture: texture, image: image,
                                                       at: transform, in: arView, w: fw, h: fh)
            }
        }

        // MARK: - Picture Frame

        /// Wall-mounted picture frame with procedural wood moulding.
        ///
        /// Coordinate convention for a vertical-plane raycast hit anchor:
        ///   Anchor X = horizontal along wall
        ///   Anchor Y = wall normal (toward camera) ← generatePlane normal = +Y, so NO rotation needed
        ///   Anchor Z = world UP
        private func placeFrameDesign(texture: TextureResource, image: UIImage,
                                      at transform: simd_float4x4, in arView: ARView,
                                      w: Float = 0.42, h: Float = 0) throws {
            let aspect  = Float(image.size.width / image.size.height)
            let dW: Float = w
            let dH: Float = h > 0 ? h : w / aspect
            let border: Float = min(dW, dH) * 0.09
            let depth: Float  = 0.022

            // No rotation needed — generatePlane normal (+Y) already faces camera.
            // Offset in Y (= wall normal direction) so moulding sits proud of wall.
            let root = Entity()
            root.position = [0, depth / 2, 0]

            // ── Design print panel (spans X=horizontal, Z=vertical) ──
            var designMat = PhysicallyBasedMaterial()
            designMat.baseColor = .init(texture: .init(texture))
            designMat.roughness = .init(floatLiteral: 0.12)
            let panel = ModelEntity(
                mesh: .generatePlane(width: dW, depth: dH),
                materials: [designMat]
            )
            root.addChild(panel)

            // ── Wood moulding bars ──
            var woodMat = PhysicallyBasedMaterial()
            woodMat.baseColor = .init(tint: UIColor(red: 0.50, green: 0.33, blue: 0.19, alpha: 1))
            woodMat.roughness = .init(floatLiteral: 0.78)
            woodMat.metallic  = .init(floatLiteral: 0.0)

            // bar(w:h:d:pos:) — size: X=horizontal width, Y=depth outward, Z=vertical thickness
            func bar(w: Float, d: Float, pos: SIMD3<Float>) {
                let e = ModelEntity(
                    mesh: .generateBox(size: [w, depth, d]),
                    materials: [woodMat]
                )
                e.position = pos
                root.addChild(e)
            }

            let outerW = dW + 2 * border
            // Top (anchor +Z = world UP)
            bar(w: outerW, d: border, pos: [0, 0,  (dH / 2 + border / 2)])
            // Bottom
            bar(w: outerW, d: border, pos: [0, 0, -(dH / 2 + border / 2)])
            // Left (inner height — corners covered by top/bottom)
            bar(w: border,  d: dH,    pos: [-(dW / 2 + border / 2), 0, 0])
            // Right
            bar(w: border,  d: dH,    pos: [ (dW / 2 + border / 2), 0, 0])

            let anchor = AnchorEntity(world: transform)
            anchor.addChild(root)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Canvas Print

        /// Wall-mounted gallery-wrap canvas: design on front face, cream sides, 38 mm depth.
        /// Anchor Y = wall normal (toward camera), X = horizontal, Z = world UP.
        private func placeCanvasDesign(texture: TextureResource, image: UIImage,
                                       at transform: simd_float4x4, in arView: ARView,
                                       w: Float = 0.40, h: Float = 0) throws {
            let aspect  = Float(image.size.width / image.size.height)
            let dW: Float = w
            let dH: Float = h > 0 ? h : w / aspect
            let depth: Float = 0.038

            // No rotation needed. Offset in Y = outward from wall.
            let root = Entity()
            root.position = [0, depth / 2, 0]

            // ── Canvas body box: X=wide, Y=depth outward, Z=tall ──
            var sideMat = PhysicallyBasedMaterial()
            sideMat.baseColor = .init(tint: UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
            sideMat.roughness = .init(floatLiteral: 0.90)
            sideMat.metallic  = .init(floatLiteral: 0.0)
            let body = ModelEntity(
                mesh: .generateBox(size: [dW, depth, dH]),
                materials: [sideMat]
            )
            root.addChild(body)

            // ── Design face — proud of box front by 1 mm in Y (toward camera) ──
            var frontMat = PhysicallyBasedMaterial()
            frontMat.baseColor = .init(texture: .init(texture))
            frontMat.roughness = .init(floatLiteral: 0.88)
            frontMat.metallic  = .init(floatLiteral: 0.0)
            let face = ModelEntity(
                mesh: .generatePlane(width: dW, depth: dH),
                materials: [frontMat]
            )
            face.position = [0, depth / 2 + 0.001, 0]
            root.addChild(face)

            let anchor = AnchorEntity(world: transform)
            anchor.addChild(root)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Retractable Banner

        /// Floor-standing retractable banner (portrait). Stands upright, yaws to face camera.
        private func placeBannerMockup(texture: TextureResource, image: UIImage,
                                       at transform: simd_float4x4, in arView: ARView,
                                       w: Float = 0.85, h: Float = 1.0) throws {
            let aspect   = Float(image.size.width / image.size.height)
            let bannerH: Float = h
            let bannerW: Float = w > 0 ? w : bannerH * min(aspect, 0.6)

            let root = Entity()
            root.orientation = cameraFacingYaw(transform: transform, arView: arView)

            // Thin box: X=wide, Y=tall, Z=1mm depth → stands upright naturally, no rotation needed.
            // The front face (+Z, toward camera) shows the design; 1mm sides are invisible at distance.
            var mat = UnlitMaterial()
            mat.color = .init(texture: .init(texture))
            let panel = ModelEntity(mesh: .generateBox(size: [bannerW, bannerH, 0.001]),
                                    materials: [mat])
            panel.position = [0, bannerH / 2, 0]
            root.addChild(panel)

            var poleMat = PhysicallyBasedMaterial()
            poleMat.baseColor = .init(tint: UIColor(white: 0.75, alpha: 1))
            poleMat.metallic  = .init(floatLiteral: 0.9)
            poleMat.roughness = .init(floatLiteral: 0.2)
            let pole = ModelEntity(mesh: .generateCylinder(height: bannerH + 0.06, radius: 0.008),
                                   materials: [poleMat])
            pole.position = [0, (bannerH + 0.06) / 2, -0.012]
            root.addChild(pole)

            var baseMat = PhysicallyBasedMaterial()
            baseMat.baseColor = .init(tint: UIColor(white: 0.55, alpha: 1))
            baseMat.metallic  = .init(floatLiteral: 0.85)
            baseMat.roughness = .init(floatLiteral: 0.3)
            let base = ModelEntity(mesh: .generateBox(size: [bannerW * 0.55, 0.04, 0.14],
                                                      cornerRadius: 0.008),
                                   materials: [baseMat])
            base.position = [0, 0.02, 0]
            root.addChild(base)

            // World-aligned anchor: take only the position from the hit transform,
            // use identity rotation so cameraFacingYaw rotates around world Y (not the
            // hit plane's local Y — which can be a wall normal, causing flipped design).
            var worldT = matrix_identity_float4x4
            worldT.columns.3 = transform.columns.3
            let anchor = AnchorEntity(world: worldT)
            anchor.addChild(root)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Billboard

        /// Large floor-standing billboard with two posts and white backing.
        private func placeBillboardMockup(texture: TextureResource, image: UIImage,
                                          at transform: simd_float4x4, in arView: ARView,
                                          w: Float = 1.2, h: Float = 0) throws {
            let aspect  = Float(image.size.width / image.size.height)
            let bbW: Float  = w
            let bbH: Float  = h > 0 ? h : bbW / max(aspect, 0.5)
            let poleH: Float = 0.55
            let signCY = poleH + bbH / 2

            let root = Entity()
            root.orientation = cameraFacingYaw(transform: transform, arView: arView)

            var boardMat = PhysicallyBasedMaterial()
            boardMat.baseColor = .init(tint: .white)
            boardMat.roughness = .init(floatLiteral: 0.85)
            // Board: X=wide, Y=tall, Z=thin depth (backing panel stands upright)
            let board = ModelEntity(mesh: .generateBox(size: [bbW + 0.03, bbH + 0.03, 0.018]),
                                    materials: [boardMat])
            board.position = [0, signCY, -0.01]
            root.addChild(board)

            // Thin box face: X=wide, Y=tall, Z=1mm → upright with +Z facing camera, no rotation.
            var faceMat = UnlitMaterial()
            faceMat.color = .init(texture: .init(texture))
            let face = ModelEntity(mesh: .generateBox(size: [bbW, bbH, 0.001]),
                                   materials: [faceMat])
            face.position = [0, signCY, 0.002]   // 2mm proud of the backing board
            root.addChild(face)

            var postMat = PhysicallyBasedMaterial()
            postMat.baseColor = .init(tint: UIColor(white: 0.45, alpha: 1))
            postMat.metallic  = .init(floatLiteral: 0.9)
            postMat.roughness = .init(floatLiteral: 0.25)
            for xOff: Float in [-bbW * 0.28, bbW * 0.28] {
                let post = ModelEntity(
                    mesh: .generateBox(size: [0.025, poleH + bbH, 0.025], cornerRadius: 0.004),
                    materials: [postMat]
                )
                post.position = [xOff, (poleH + bbH) / 2, -0.012]
                root.addChild(post)
            }

            var worldT = matrix_identity_float4x4
            worldT.columns.3 = transform.columns.3
            let anchor = AnchorEntity(world: worldT)
            anchor.addChild(root)
            arView.scene.addAnchor(anchor)
        }

        /// Yaw-only rotation so a floor-placed entity faces the camera.
        private func cameraFacingYaw(transform: simd_float4x4, arView: ARView) -> simd_quatf {
            guard let cam = arView.session.currentFrame?.camera.transform else {
                return simd_quatf(angle: 0, axis: [0, 1, 0])
            }
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let hitPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let diff   = SIMD3<Float>(camPos.x - hitPos.x, 0, camPos.z - hitPos.z)
            let yaw    = length(diff) > 0.01 ? atan2(diff.x, diff.z) : 0
            return simd_quatf(angle: yaw, axis: [0, 1, 0])
        }

        // MARK: - Flat

        private func placeFlatDesign(texture: TextureResource, image: UIImage,
                                     at transform: simd_float4x4, in arView: ARView,
                                     w: Float = 0.3, h: Float = 0) throws {
            var mat = UnlitMaterial()
            mat.color = .init(texture: .init(texture))
            let aspect = Float(image.size.width / image.size.height)
            let finalH: Float = h > 0 ? h : w / aspect
            let plane = ModelEntity(mesh: .generatePlane(width: w, depth: finalH), materials: [mat])
            let anchor = AnchorEntity(world: transform)
            anchor.addChild(plane)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Yard Sign

        /// Floor-planted yard sign: upright corrugated panel with H-wire stakes.
        private func placeYardSignMockup(texture: TextureResource, image: UIImage,
                                         at transform: simd_float4x4, in arView: ARView,
                                         w: Float = 0.60, h: Float = 0.45) throws {
            let aspect = Float(image.size.width / image.size.height)
            let sW: Float = w
            let sH: Float = h > 0 ? h : sW / aspect

            let root = Entity()
            root.orientation = cameraFacingYaw(transform: transform, arView: arView)

            // ── Sign face (upright, facing camera) ──
            // Thin box: X=wide, Y=tall, Z=1mm → upright with +Z facing camera, no rotation.
            var mat = UnlitMaterial()
            mat.color = .init(texture: .init(texture))
            let face = ModelEntity(mesh: .generateBox(size: [sW, sH, 0.001]), materials: [mat])
            face.position = [0, sH / 2, 0.002]   // 2mm in front of stakes
            root.addChild(face)

            // ── H-wire stakes ──
            var wireMat = PhysicallyBasedMaterial()
            wireMat.baseColor = .init(tint: UIColor(white: 0.25, alpha: 1))
            wireMat.metallic  = .init(floatLiteral: 0.9)
            wireMat.roughness = .init(floatLiteral: 0.25)

            let stakeH: Float = sH + 0.18   // extends 0.12m above sign + 0.06m into ground
            for xOff: Float in [-sW * 0.25, sW * 0.25] {
                let stake = ModelEntity(
                    mesh: .generateCylinder(height: stakeH, radius: 0.0025),
                    materials: [wireMat]
                )
                // Centre stake so bottom 0.06m is below anchor (ground)
                stake.position = [xOff, stakeH / 2 - 0.06, -0.006]
                root.addChild(stake)
            }

            // Horizontal H-bar across the middle of the sign
            let hbar = ModelEntity(
                mesh: .generateCylinder(height: sW * 0.60, radius: 0.0025),
                materials: [wireMat]
            )
            hbar.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            hbar.position    = [0, sH * 0.5, -0.006]
            root.addChild(hbar)

            var worldT = matrix_identity_float4x4
            worldT.columns.3 = transform.columns.3
            let anchor = AnchorEntity(world: worldT)
            anchor.addChild(root)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Mug

        private func placeMugMockup(texture: TextureResource,
                                    at transform: simd_float4x4, in arView: ARView) throws {
            var mat = UnlitMaterial()
            mat.color = .init(texture: .init(texture))
            let body = ModelEntity(mesh: .generateCylinder(height: 0.12, radius: 0.045),
                                   materials: [mat])
            let handle = ModelEntity(
                mesh: .generateBox(size: [0.015, 0.07, 0.01], cornerRadius: 0.005),
                materials: [SimpleMaterial(color: .white, isMetallic: false)]
            )
            handle.position = [0.055, 0, 0]
            let base = ModelEntity(
                mesh: .generatePlane(width: 0.15, depth: 0.15),
                materials: [SimpleMaterial(color: .init(white: 0.9, alpha: 0.4), isMetallic: false)]
            )
            base.position = [0, -0.061, 0]
            let anchor = AnchorEntity(world: transform)
            anchor.addChild(body)
            body.addChild(handle)
            anchor.addChild(base)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Phone Case

        private func placePhoneCaseMockup(texture: TextureResource,
                                          at transform: simd_float4x4, in arView: ARView) throws {
            var mat = UnlitMaterial()
            mat.color = .init(texture: .init(texture))
            let caseBody = ModelEntity(
                mesh: .generateBox(size: [0.075, 0.155, 0.008], cornerRadius: 0.012),
                materials: [SimpleMaterial(color: .black, isMetallic: true)]
            )
            let design = ModelEntity(mesh: .generatePlane(width: 0.065, depth: 0.13),
                                     materials: [mat])
            design.position = [0, 0, 0.005]
            let anchor = AnchorEntity(world: transform)
            anchor.addChild(caseBody)
            caseBody.addChild(design)
            arView.scene.addAnchor(anchor)
        }

        // MARK: - Helpers

        private func updateStatus(_ msg: String) {
            DispatchQueue.main.async { self.statusMessage = msg }
        }
    }
}
