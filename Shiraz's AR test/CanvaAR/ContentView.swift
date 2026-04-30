import SwiftUI

struct ContentView: View {
    @EnvironmentObject var api: CanvaAPIService

    @State private var showDesignPicker  = false
    @State private var selectedImageURL: URL?
    @State private var selectedTitle:    String?
    @State private var statusMessage     = "Scan a flat surface to begin"
    @State private var isExporting       = false
    @State private var placementMode: PlacementMode = .flat

    var body: some View {
        ZStack {
            // AR view fills the screen
            ARViewContainer(
                selectedImageURL: $selectedImageURL,
                placementMode:    $placementMode,
                statusMessage:    $statusMessage
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Status pill ────────────────────────────────────────────
                Text(statusMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 56)
                    .animation(.easeInOut, value: statusMessage)

                Spacer()

                // ── Mockup mode picker ─────────────────────────────────────
                if selectedImageURL != nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(PlacementMode.allCases, id: \.self) { mode in
                                Button {
                                    placementMode = mode
                                } label: {
                                    Label(mode.rawValue, systemImage: mode.icon)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            placementMode == mode
                                                ? Color.purple
                                                : Color.black.opacity(0.5),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 12)
                }

                // ── Bottom controls ────────────────────────────────────────
                HStack(spacing: 12) {
                    if !api.isAuthenticated {
                        Button {
                            Task { await api.signIn() }
                        } label: {
                            Label("Connect Canva", systemImage: "link")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)

                    } else {
                        // Pick / change design
                        Button {
                            showDesignPicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "paintbrush.pointed")
                                Text(selectedTitle ?? "Pick Design")
                                    .lineLimit(1)
                            }
                            .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isExporting)

                        if isExporting {
                            ProgressView()
                                .tint(.white)
                        }

                        // Clear
                        if selectedImageURL != nil {
                            Button {
                                selectedImageURL = nil
                                selectedTitle    = nil
                                statusMessage    = "Scan a flat surface to begin"
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: $showDesignPicker) {
            DesignPickerView { design in
                showDesignPicker = false
                selectedTitle    = design.title ?? "Untitled"
                statusMessage    = "Exporting \"\(selectedTitle ?? "design")\"…"
                isExporting      = true

                Task {
                    do {
                        selectedImageURL = try await api.exportDesign(id: design.id)
                        statusMessage    = "Tap a surface to place your design"
                    } catch {
                        statusMessage = "Export failed: \(error.localizedDescription)"
                    }
                    isExporting = false
                }
            }
        }
        .alert("Auth Error", isPresented: .constant(api.authError != nil)) {
            Button("OK") { api.authError = nil }
        } message: {
            Text(api.authError ?? "")
        }
    }
}
