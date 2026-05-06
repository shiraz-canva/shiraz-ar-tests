import SwiftUI

// MARK: - Canva AR Scan Coaching Overlay
//
// Replaces Apple's stock ARCoachingOverlayView with a Canva-branded
// scanning grid. Shows while ARKit is searching for a surface.

struct ARScanCoachingView: View {
    let mode: PlacementMode

    @State private var scanPhase: CGFloat = 0   // 0→1, drives sweep line
    @State private var appeared  = false

    var body: some View {
        ZStack {
            // ── Dark scrim ────────────────────────────────────────────
            Color.black.opacity(0.58)

            VStack(spacing: 0) {
                Spacer()

                // ── Scanning grid ─────────────────────────────────────
                ScanGridView(phase: scanPhase, vertical: mode.prefersWall)
                    .frame(width: 300,
                           height: mode.prefersWall ? 230 : 170)
                    .opacity(appeared ? 1 : 0)
                    .padding(.bottom, 40)

                // ── Labels ────────────────────────────────────────────
                VStack(spacing: 10) {
                    Text(mode.prefersWall ? "Point at a wall" : "Move your phone slowly")
                        .font(Easel.body(20, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(mode.prefersWall
                         ? "Keep your phone steady and pan across a wall"
                         : "Scan a flat surface like a floor or table")
                        .font(Easel.body(14))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .opacity(appeared ? 1 : 0)

                Spacer().frame(height: 140)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.45)) { appeared = true }
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                scanPhase = 1
            }
        }
    }
}

// MARK: - Animated grid canvas

private struct ScanGridView: View {
    let phase: CGFloat   // 0→1 looping — controls sweep line position
    let vertical: Bool   // wall mode → no perspective tilt

    private let cols = 8
    private let rows = 6
    private let purple = Color(hex: "#8B3DFF")
    private let purpleBright = Color(hex: "#A855F7")

    var body: some View {
        Canvas { ctx, size in
            let cW     = size.width  / CGFloat(cols)
            let cH     = size.height / CGFloat(rows)
            let sweepY = size.height * phase

            // ── Grid lines ───────────────────────────────────────────
            // Horizontal
            for row in 0...rows {
                let y       = cH * CGFloat(row)
                let scanned = y <= sweepY
                var p = Path()
                p.move(to: CGPoint(x: 0,          y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p,
                    with: .color(purple.opacity(scanned ? 0.80 : 0.15)),
                    lineWidth: scanned ? 1.0 : 0.5)
            }

            // Vertical
            for col in 0...cols {
                let x = cW * CGFloat(col)
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p,
                    with: .color(purple.opacity(phase > 0.05 ? 0.38 : 0.15)),
                    lineWidth: 0.5)
            }

            // ── Intersection dots (scanned region only) ───────────────
            for row in 0...rows {
                for col in 0...cols {
                    let pt = CGPoint(x: cW * CGFloat(col),
                                     y: cH * CGFloat(row))
                    guard pt.y <= sweepY - 6 else { continue }
                    let r: CGFloat = 2.5
                    let dot = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r,
                                                     width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(purple.opacity(0.90)))
                }
            }

            // ── Sweep line glow (layered strokes) ────────────────────
            guard sweepY > 0 && sweepY < size.height else { return }

            for i in stride(from: 0, through: 28, by: 4) {
                let offset = CGFloat(i)
                var g = Path()
                g.move(to: CGPoint(x: 0,          y: max(0, sweepY - offset)))
                g.addLine(to: CGPoint(x: size.width, y: max(0, sweepY - offset)))
                ctx.stroke(g,
                    with: .color(purple.opacity(0.05 * (1.0 - offset / 28.0))),
                    lineWidth: 10)
            }

            // Bright scan line
            var scanLine = Path()
            scanLine.move(to: CGPoint(x: 0,          y: sweepY))
            scanLine.addLine(to: CGPoint(x: size.width, y: sweepY))
            ctx.stroke(scanLine, with: .color(purpleBright), lineWidth: 2.5)
        }
        // Perspective tilt makes the grid read as a floor in floor mode.
        // Wall mode stays flat (like scanning across a vertical surface).
        .rotation3DEffect(
            vertical ? .degrees(0) : .degrees(54),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.45
        )
    }
}
