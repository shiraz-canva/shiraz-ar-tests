import SwiftUI

struct ContentView: View {
    @EnvironmentObject var api: CanvaAPIService

    @State private var selectedImageURL: URL?
    @State private var placementMode: PlacementMode = .flat
    @State private var selectedFormat: PrintFormat = PrintFormat.all[0]
    @State private var statusMessage = "Point at a flat surface"
    @State private var showDesignPicker = false
    @State private var isExporting = false
    @State private var selectedDesign: CanvaDesign?
    @State private var useFrontCamera = false

    var body: some View {
        ZStack {
            ARViewContainer(
                selectedImageURL: $selectedImageURL,
                placementMode: $placementMode,
                selectedFormat: $selectedFormat,
                statusMessage: $statusMessage,
                useFrontCamera: $useFrontCamera
            )
            .ignoresSafeArea()

            VStack {
                // Top: Status message (more prominent)
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(statusMessage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()

                    if placementMode == .tshirt {
                        Button {
                            useFrontCamera.toggle()
                        } label: {
                            Image(systemName: useFrontCamera ? "camera.fill" : "arrow.triangle.2.circlepath.camera.fill")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.trailing, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                .padding(16)

                Spacer()

                // Bottom: Auth button or (Design picker + Product picker)
                VStack(spacing: 16) {
                    if !api.isAuthenticated {
                        Button {
                            Task { await api.signIn() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.badge.key")
                                Text("Connect Canva")
                            }
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.horizontal, 16)
                    } else {
                        // Design picker CTA
                        Button {
                            showDesignPicker = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selectedDesign == nil ? "photo.on.rectangle" : "checkmark.circle.fill")
                                Text(selectedDesign == nil ? "Pick a Design" : (selectedDesign?.title ?? "Design Selected"))
                                    .lineLimit(1)
                                Spacer()
                                if isExporting {
                                    ProgressView()
                                        .tint(.white)
                                }
                            }
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isExporting)
                        .padding(.horizontal, 16)

                        // Product picker (only show if design is loaded)
                        if selectedImageURL != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Choose a Product")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(PrintFormat.all) { format in
                                            ProductCard(
                                                format: format,
                                                isSelected: selectedFormat.id == format.id,
                                                action: {
                                                    selectedFormat = format
                                                    placementMode = format.suggestedMode
                                                    if format.suggestedMode != .tshirt { useFrontCamera = false }
                                                    statusMessage = format.suggestedMode.placementHint
                                                }
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                            .padding(.bottom, 8)
                        }

                        // Clear design button
                        if selectedImageURL != nil {
                            Button {
                                selectedImageURL = nil
                                selectedDesign = nil
                                useFrontCamera = false
                                statusMessage = placementMode.placementHint
                            } label: {
                                Text("Clear Design")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showDesignPicker) {
            DesignPickerView { design in
                showDesignPicker = false
                selectedDesign = design
                exportDesign(design)
            }
        }
        .alert("Sign-in Error", isPresented: Binding(
            get: { api.authError != nil },
            set: { if !$0 { api.authError = nil } }
        )) {
            Button("OK") { api.authError = nil }
        } message: {
            Text(api.authError ?? "")
        }
        .onOpenURL { url in handleDeepLink(url) }
    }

    // MARK: - Product Card View

    private func ProductCard(
        format: PrintFormat,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: format.icon)
                    .font(.title3)
                Text(format.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(format.displayDimensions)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 80)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(isSelected ? Color(red: 0.49, green: 0.17, blue: 0.91) : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color(red: 0.49, green: 0.17, blue: 0.91) : Color.clear,
                        lineWidth: 2
                    )
            )
        }
    }

    // MARK: - Deep Link

    private func handleDeepLink(_ url: URL) {
        guard
            url.scheme == "canvaar",
            url.host == "preview",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let designID = components.queryItems?.first(where: { $0.name == "design_id" })?.value
        else { return }

        let product = components.queryItems?.first(where: { $0.name == "product" })?.value ?? "poster"
        switch product {
        case "tshirt", "t-shirt", "apparel":    placementMode = .tshirt
        case "mug", "cup":                       placementMode = .mug
        case "phonecase", "phone-case":          placementMode = .phoneCase
        case "frame", "picture-frame":           placementMode = .frame
        case "canvas", "canvas-print":           placementMode = .canvas
        case "banner":                           placementMode = .banner
        case "billboard":                        placementMode = .billboard
        default:                                 placementMode = .flat
        }
        statusMessage = "Loading design…"
        Task {
            if !api.isAuthenticated {
                await api.signIn()
                guard api.isAuthenticated else { return }
            }
            let mockDesign = CanvaDesign(id: designID, title: "AR Preview", thumbnail: nil)
            selectedDesign = mockDesign
            exportDesign(mockDesign)
        }
    }

    private func exportDesign(_ design: CanvaDesign) {
        isExporting = true
        statusMessage = "Exporting \(design.title ?? "design")…"
        Task {
            do {
                let url = try await api.exportDesign(id: design.id)
                selectedImageURL = url
                statusMessage = placementMode.placementHint
            } catch {
                statusMessage = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }
}
