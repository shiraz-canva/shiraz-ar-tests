import SwiftUI

// MARK: - Easel Design System tokens
// Source: 🎨 Easel-Design-System / 🌈 Theme (☀️ Light)

enum Easel {
    // Colours
    static let primaryBg         = Color(hex: "#8B3DFF") // action/primary/bg
    static let primaryBgHovered  = Color(hex: "#7630D7") // action/primary/bg-hovered
    static let primaryFg         = Color.white            // action/primary/fg

    static let surfaceBg         = Color(hex: "#FFFFFF") // surface/bg
    static let sunkenBg          = Color(hex: "#F3F4F7") // surface/sunken-bg (card fill)

    static let contentFg         = Color(hex: "#0F1015") // content/fg (primary text)
    static let contentSubtle     = Color(hex: "#404f6d").opacity(0.72) // approx subtle

    static let borderFocused     = Color(hex: "#8B3DFF") // control/border-focused (selection)
    static let hintSubtleBg      = Color(hex: "#E7DBFF") // feedback/hint/subtle-bg (sel tint)

    // Radius
    static let radiusCard: CGFloat  = 16   // radius/16
    static let radiusPanel: CGFloat = 24   // radius/24
    static let radiusFull: CGFloat  = 9999 // radius/full (pill buttons)
    static let radiusSmall: CGFloat = 8    // radius/08

    // Spacing
    static let space025: CGFloat = 2
    static let space050: CGFloat = 4
    static let space100: CGFloat = 8
    static let space150: CGFloat = 12
    static let space200: CGFloat = 16
    static let space300: CGFloat = 24
    static let space400: CGFloat = 32

    // Typography helpers — swap "CanvaSans" for system when font not bundled
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
        // Once Canva Sans is in the bundle, replace with:
        // weight == .semibold ? .custom("CanvaSans-SemiBold", size: size)
        //                     : .custom("CanvaSans-Regular",  size: size)
    }
}

// MARK: - Hex colour init helper

extension Color {
    init(hex: String) {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - ContentView

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
        ZStack(alignment: .bottom) {
            // ── AR view (full screen) ─────────────────────────────────────────
            ARViewContainer(
                selectedImageURL: $selectedImageURL,
                placementMode: $placementMode,
                selectedFormat: $selectedFormat,
                statusMessage: $statusMessage,
                useFrontCamera: $useFrontCamera
            )
            .ignoresSafeArea()

            // ── Status pill (top) ─────────────────────────────────────────────
            VStack {
                statusPill
                    .padding(.top, 12)
                    .padding(.horizontal, Easel.space200)
                Spacer()
            }

            // ── Bottom panel ──────────────────────────────────────────────────
            bottomPanel
        }
        .sheet(isPresented: $showDesignPicker) {
            DesignPickerView { design in
                showDesignPicker = false
                selectedDesign = design
                exportDesign(design)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)  // we draw our own drag handle
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

    // MARK: - Status pill

    private var statusPill: some View {
        HStack(spacing: Easel.space100) {
            Text(statusMessage)
                .font(Easel.body(14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            if placementMode == .tshirt {
                Button {
                    useFrontCamera.toggle()
                } label: {
                    Image(systemName: useFrontCamera
                          ? "camera.fill"
                          : "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(Easel.space100)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .padding(.horizontal, Easel.space200)
        .padding(.vertical, Easel.space100 + 2)
        .background(.black.opacity(0.45), in: Capsule())
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            if !api.isAuthenticated {
                connectSection
            } else {
                if selectedImageURL != nil {
                    productPickerSection
                }
                ctaSection
            }
        }
        .background(Easel.surfaceBg)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Easel.radiusPanel,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Easel.radiusPanel,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Connect section

    private var connectSection: some View {
        VStack(spacing: Easel.space150) {
            Text("Connect your Canva account to preview designs in AR.")
                .font(Easel.body(14))
                .foregroundStyle(Easel.contentFg.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Easel.space200)
                .padding(.top, Easel.space300)

            easelButton(label: "Connect Canva", icon: "person.badge.key") {
                Task { await api.signIn() }
            }
            .padding(.horizontal, Easel.space200)
            .padding(.bottom, Easel.space300)
        }
    }

    // MARK: - Product picker (Canva resize-menu style)

    private var productPickerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text("Choose a Product")
                    .font(Easel.body(12, weight: .semibold))
                    .foregroundStyle(Easel.contentFg.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, Easel.space200)
            .padding(.top, Easel.space200)
            .padding(.bottom, Easel.space150)

            // Cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Easel.space150) {
                    ForEach(PrintFormat.all) { format in
                        productCard(for: format)
                    }
                }
                .padding(.horizontal, Easel.space200)
                .padding(.bottom, Easel.space200)
            }

            Divider()
                .padding(.horizontal, Easel.space200)
        }
    }

    private func productCard(for format: PrintFormat) -> some View {
        let isSelected = selectedFormat.id == format.id

        return Button {
            selectedFormat = format
            placementMode  = format.suggestedMode
            if format.suggestedMode != .tshirt { useFrontCamera = false }
            statusMessage  = format.suggestedMode.placementHint
        } label: {
            VStack(alignment: .leading, spacing: Easel.space100) {
                // Thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: Easel.radiusCard, style: .continuous)
                        .fill(isSelected ? Easel.hintSubtleBg : Easel.sunkenBg)

                    ProductThumbnailView(format: format)
                        .padding(Easel.space150)
                }
                .frame(width: 128, height: 108)
                .overlay(
                    RoundedRectangle(cornerRadius: Easel.radiusCard, style: .continuous)
                        .stroke(isSelected ? Easel.borderFocused : Color.clear, lineWidth: 2)
                )

                // Product name
                Text(format.longName)
                    .font(Easel.body(13, weight: .semibold))
                    .foregroundStyle(Easel.contentFg)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 128, alignment: .leading)

                // Dimensions
                Text(format.displayDimensions)
                    .font(Easel.body(12))
                    .foregroundStyle(Easel.contentFg.opacity(0.55))
                    .frame(width: 128, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - CTA section

    private var ctaSection: some View {
        HStack(spacing: Easel.space150) {
            // Pick / Design button
            easelButton(
                label: selectedDesign == nil ? "Pick a Design" : (selectedDesign?.title ?? "Design Selected"),
                icon: selectedDesign == nil ? "photo.on.rectangle.angled" : "checkmark.circle.fill",
                isLoading: isExporting
            ) {
                showDesignPicker = true
            }
            .disabled(isExporting)

            // Clear button (only when design is placed)
            if selectedImageURL != nil {
                Button {
                    selectedImageURL = nil
                    selectedDesign   = nil
                    useFrontCamera   = false
                    statusMessage    = placementMode.placementHint
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Easel.contentFg)
                        .frame(width: 48, height: 48)
                        .background(Easel.sunkenBg, in: Circle())
                }
            }
        }
        .padding(.horizontal, Easel.space200)
        .padding(.vertical, Easel.space200)
        .padding(.bottom, Easel.space200) // extra above home indicator
    }

    // MARK: - Easel primary button

    private func easelButton(
        label: String,
        icon: String? = nil,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Easel.space100) {
                if isLoading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(label)
                    .font(Easel.body(15, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Easel.primaryFg)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Easel.primaryBg, in: Capsule())
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

// MARK: - PrintFormat display helpers

extension PrintFormat {
    /// Full product name matching Canva's resize menu labels
    var longName: String {
        switch id {
        case "a4":        return "Flyer (Portrait A4)"
        case "a3":        return "Poster (Portrait A3)"
        case "a2":        return "Poster (Portrait A2)"
        case "a1":        return "Poster (Portrait A1)"
        case "canvas":    return "Canvas Print"
        case "yard_sign": return "Yard Sign (Landscape)"
        case "banner":    return "Retractable Banner"
        case "billboard": return "Billboard"
        default:          return name
        }
    }
}

// MARK: - Product thumbnail illustrations

/// Simplified product illustrations using Canva's #8B3DFF brand purple,
/// matching the visual style of the Canva resize menu.
struct ProductThumbnailView: View {

    let format: PrintFormat

    // Easel primary purple
    private let purple = Color(red: 0.545, green: 0.239, blue: 1.0)
    private let purpleDark = Color(red: 0.380, green: 0.176, blue: 0.682)
    private let purpleLight = Color(red: 0.906, green: 0.859, blue: 1.0)

    var body: some View {
        switch format.id {
        case "a4":        flyer
        case "a3", "a2",
             "a1":        poster(scale: format.id == "a1" ? 1.0 : 0.88)
        case "canvas":    canvas
        case "yard_sign": yardSign
        case "banner":    banner
        case "billboard": billboard
        default:          genericIcon
        }
    }

    // ── Flyer (A4) — portrait, smaller ──────────────────────────────
    private var flyer: some View {
        GeometryReader { g in
            let w = g.size.width * 0.55, h = g.size.height * 0.88
            ZStack {
                // Paper
                RoundedRectangle(cornerRadius: 4)
                    .fill(purple)
                    .frame(width: w, height: h)
                // Design chrome — header block + lines
                VStack(spacing: h * 0.05) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(purpleDark)
                        .frame(width: w * 0.72, height: h * 0.28)
                    VStack(spacing: h * 0.06) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(purpleLight.opacity(0.7))
                            .frame(width: w * 0.60, height: h * 0.07)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(purpleLight.opacity(0.45))
                            .frame(width: w * 0.48, height: h * 0.06)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ── Poster (A3/A2/A1) — taller ──────────────────────────────────
    private func poster(scale: CGFloat) -> some View {
        GeometryReader { g in
            let w = g.size.width * 0.60 * scale, h = g.size.height * 0.96 * scale
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(purple)
                    .frame(width: w, height: h)
                VStack(spacing: h * 0.06) {
                    // Circles row
                    HStack(spacing: w * 0.08) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(purpleDark)
                            .frame(width: w * 0.40, height: w * 0.40)
                        Circle()
                            .fill(purpleLight.opacity(0.3))
                            .frame(width: w * 0.28, height: w * 0.28)
                    }
                    // Lines
                    RoundedRectangle(cornerRadius: 2)
                        .fill(purpleLight.opacity(0.7))
                        .frame(width: w * 0.68, height: h * 0.06)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(purpleLight.opacity(0.40))
                        .frame(width: w * 0.50, height: h * 0.05)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ── Canvas Print — square ───────────────────────────────────────
    private var canvas: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) * 0.82
            ZStack {
                // Cream wrap edge
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: 0.93, green: 0.91, blue: 0.87))
                    .frame(width: s + 7, height: s + 7)
                // Purple face
                RoundedRectangle(cornerRadius: 3)
                    .fill(purple)
                    .frame(width: s, height: s)
                // Simple icon
                Image(systemName: "photo.artframe")
                    .font(.system(size: s * 0.32, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ── Yard Sign — landscape on H-stakes ──────────────────────────
    private var yardSign: some View {
        GeometryReader { g in
            let sw = g.size.width * 0.86, sh = g.size.height * 0.46
            let wireH = g.size.height * 0.40
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Sign face
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(purple)
                            .frame(width: sw, height: sh)
                        // Logo mark
                        RoundedRectangle(cornerRadius: 3)
                            .fill(purpleDark)
                            .frame(width: sw * 0.26, height: sh * 0.50)
                            .offset(x: -sw * 0.22)
                        // Lines
                        VStack(spacing: sh * 0.12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(purpleLight.opacity(0.7))
                                .frame(width: sw * 0.38, height: sh * 0.13)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(purpleLight.opacity(0.4))
                                .frame(width: sw * 0.30, height: sh * 0.10)
                        }
                        .offset(x: sw * 0.12)
                    }
                    // H-stakes
                    HStack(spacing: sw * 0.44) {
                        Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 2, height: wireH)
                        Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 2, height: wireH)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ── Retractable Banner — portrait, with stand ──────────────────
    private var banner: some View {
        GeometryReader { g in
            let bw = g.size.width * 0.40, bh = g.size.height * 0.72
            let baseH: CGFloat = 8, baseW = bw * 1.3
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Panel
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(purple)
                            .frame(width: bw, height: bh)
                        // Photo + lines
                        VStack(spacing: bh * 0.06) {
                            Circle()
                                .fill(purpleDark)
                                .frame(width: bw * 0.52, height: bw * 0.52)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(purpleLight.opacity(0.7))
                                .frame(width: bw * 0.64, height: bh * 0.07)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(purpleLight.opacity(0.4))
                                .frame(width: bw * 0.50, height: bh * 0.06)
                        }
                    }
                    // Pole
                    Rectangle()
                        .fill(Color.gray.opacity(0.45))
                        .frame(width: 2, height: g.size.height * 0.06)
                    // Base
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.45))
                        .frame(width: baseW, height: baseH)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ── Billboard — landscape with two posts ────────────────────────
    private var billboard: some View {
        GeometryReader { g in
            let bw = g.size.width * 0.88, bh = g.size.height * 0.48
            let postH = g.size.height * 0.38
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Billboard face
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(purple)
                            .frame(width: bw, height: bh)
                        HStack(spacing: bw * 0.05) {
                            Circle()
                                .fill(purpleDark)
                                .frame(width: bh * 0.52, height: bh * 0.52)
                            VStack(alignment: .leading, spacing: bh * 0.10) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(purpleLight.opacity(0.7))
                                    .frame(width: bw * 0.36, height: bh * 0.13)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(purpleLight.opacity(0.4))
                                    .frame(width: bw * 0.27, height: bh * 0.10)
                            }
                        }
                    }
                    // Posts
                    HStack(spacing: bw * 0.48) {
                        Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 3, height: postH)
                        Rectangle().fill(Color.gray.opacity(0.5)).frame(width: 3, height: postH)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var genericIcon: some View {
        Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(Color(red: 0.545, green: 0.239, blue: 1.0).opacity(0.5))
    }
}
