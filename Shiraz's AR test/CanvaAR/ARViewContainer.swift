import SwiftUI
import RealityKit
import ARKit

/// Wraps a RealityKit ARView for use in SwiftUI.
/// Handles plane detection, tap-to-place, and mockup placement modes.
struct ARViewContainer: UIViewRepresentable {

    @Binding var selectedImageURL: URL?
    @Binding var placementMode: PlacementMode
    @Binding var statusMessage: String

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // World tracking + plane detection
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        arView.session.run(config)

        // Coaching overlay guides user to find surfaces
        let coaching = ARCoachingOverlayView()
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.session = arView.session
        coaching.goal    = .horizontalPlane
        arView.addSubview(coaching)

        // Tap gesture
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tap)

        context.coordinator.arView = arView
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.pendingImageURL = selectedImageURL
        context.coordinator.placementMode   = placementMode
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(statusMessage: $statusMessage)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var arView: ARView?
        var pendingImageURL: URL?
        var placementMode: PlacementMode = .flat
        @Binding var statusMessage: String

        init(statusMessage: Binding<String>) {
            _statusMessage = statusMessage
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }

            guard pendingImageURL != nil else {
                updateStatus("Pick a design first ☝️")
                return
            }

            let pt = gesture.location(in: arView)
            let results = arView.raycast(from: pt, allowing: .estimatedPlane, alignment: .any)

            guard let hit = results.first else {
                updateStatus("No surface found — keep scanning")
                return
            }

            Task { await placeDesign(at: hit.worldTransform, in: arView) }
        }

        @MainActor
        func placeDesign(at transform: simd_float4x4, in arView: ARView) async {
            guard let imageURL = pendingImageURL else { return }
            updateStatus("Fetching image…")

            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
                    updateStatus("Couldn't load image"); return
                }

                let texture = try await TextureResource(image: cgImage, options: .init(semantic: .color))

                switch placementMode {
                case .flat:        try placeFlatDesign(texture: texture, image: uiImage, at: transform, in: arView)
                case .mug:         try placeMugMockup(texture: texture, at: transform, in: arView)
                case .tshirt:      try placeTshirtMockup(texture: texture, image: uiImage, at: transform, in: arView)
                case .phoneCase:   try placePhoneCaseMockup(texture: texture, at: transform, in: arView)
                }

                updateStatus("Tap again to place another")
            } catch {
                updateStatus("Error: \(error.localizedDescription)")
            }
        }

        // MARK: Flat Surface

        private func placeFlatDesign(
            texture: TextureResource,
            image: UIImage,
            at transform: simd_float4x4,
            in arView: ARView
        ) throws {
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))

            let aspectRatio = Float(image.size.width / image.size.height)
            let width: Float = 0.3 // 30 cm
            let height = width / aspectRatio

            let plane = ModelEntity(
                mesh: .generatePlane(width: width, depth: height),
                materials: [material]
            )

            let anchor = AnchorEntity(world: transform)
            anchor.addChild(plane)
            arView.scene.addAnchor(anchor)
        }

        // MARK: Mug Mockup
        // Wraps the design around a cylinder (mug body).

        private func placeMugMockup(
            texture: TextureResource,
            at transform: simd_float4x4,
            in arView: ARView
        ) throws {
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))

            // Mug body — cylinder
            let body = ModelEntity(
                mesh: .generateCylinder(height: 0.12, radius: 0.045),
                materials: [material]
            )

            // Handle — torus approximated by a thin curved box
            var handleMat = SimpleMaterial(color: .white, isMetallic: false)
            let handle = ModelEntity(
                mesh: .generateBox(size: [0.015, 0.07, 0.01], cornerRadius: 0.005),
                materials: [handleMat]
            )
            handle.position = [0.055, 0, 0]

            // Base plane (table shadow catcher)
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

        // MARK: T-Shirt Mockup
        // Places design on a flat rectangular "shirt front" panel.

        private func placeTshirtMockup(
            texture: TextureResource,
            image: UIImage,
            at transform: simd_float4x4,
            in arView: ARView
        ) throws {
            var printMaterial = UnlitMaterial()
            printMaterial.color = .init(texture: .init(texture))

            // Shirt body (white panel)
            var shirtMat = SimpleMaterial(color: .white, isMetallic: false)
            let shirt = ModelEntity(
                mesh: .generateBox(size: [0.28, 0.32, 0.005], cornerRadius: 0.01),
                materials: [shirtMat]
            )

            // Design print area (front centre)
            let aspectRatio = Float(image.size.width / image.size.height)
            let printWidth: Float = 0.14
            let printHeight = printWidth / aspectRatio
            let printPlane = ModelEntity(
                mesh: .generatePlane(width: printWidth, depth: printHeight),
                materials: [printMaterial]
            )
            printPlane.position = [0, 0, 0.003] // just in front of shirt surface

            let anchor = AnchorEntity(world: transform)
            anchor.addChild(shirt)
            shirt.addChild(printPlane)
            arView.scene.addAnchor(anchor)
        }

        // MARK: Phone Case Mockup

        private func placePhoneCaseMockup(
            texture: TextureResource,
            at transform: simd_float4x4,
            in arView: ARView
        ) throws {
            var printMaterial = UnlitMaterial()
            printMaterial.color = .init(texture: .init(texture))

            // Phone case body
            var caseMat = SimpleMaterial(color: .black, isMetallic: true)
            let caseBody = ModelEntity(
                mesh: .generateBox(size: [0.075, 0.155, 0.008], cornerRadius: 0.012),
                materials: [caseMat]
            )

            // Design on the back
            let designPlane = ModelEntity(
                mesh: .generatePlane(width: 0.065, depth: 0.13),
                materials: [printMaterial]
            )
            designPlane.position = [0, 0, 0.005]

            let anchor = AnchorEntity(world: transform)
            anchor.addChild(caseBody)
            caseBody.addChild(designPlane)
            arView.scene.addAnchor(anchor)
        }

        // MARK: Helpers

        private func updateStatus(_ msg: String) {
            DispatchQueue.main.async { self.statusMessage = msg }
        }
    }
}
