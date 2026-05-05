import SwiftUI

struct DesignPickerView: View {
    @EnvironmentObject var api: CanvaAPIService
    @Environment(\.dismiss) private var dismiss

    @State private var designs:  [CanvaDesign] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var searchText = ""

    let onSelect: (CanvaDesign) -> Void

    // ── Figma reference: 2-column grid, thumbnails fill the card ──────────────
    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    private var filtered: [CanvaDesign] {
        guard !searchText.isEmpty else { return designs }
        return designs.filter { ($0.title ?? "").localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Drag handle ──────────────────────────────────────────────────
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: "#D1D5DB"))
                .frame(width: 36, height: 4)
                .padding(.top, Easel.space150)
                .padding(.bottom, Easel.space100)

            // ── Inline title bar ─────────────────────────────────────────────
            ZStack {
                Text("Select a design")
                    .font(Easel.body(17, weight: .semibold))
                    .foregroundStyle(Easel.contentFg)
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Easel.contentFg)
                            .frame(width: 32, height: 32)
                            .background(Color(hex: "#E4E6EC"), in: Circle())
                    }
                }
                .padding(.trailing, Easel.space200)
            }
            .frame(height: 44)
            .padding(.horizontal, Easel.space200)

            // ── Search bar ───────────────────────────────────────────────────
            HStack(spacing: Easel.space100) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Easel.contentFg.opacity(0.4))
                TextField("Search your designs", text: $searchText)
                    .font(Easel.body(15))
                    .foregroundStyle(Easel.contentFg)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Easel.contentFg.opacity(0.35))
                    }
                }
            }
            .padding(.horizontal, Easel.space150)
            .frame(height: 44)
            .background(Easel.sunkenBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, Easel.space200)
            .padding(.vertical, Easel.space150)

            Divider()

            // ── Content ──────────────────────────────────────────────────────
            Group {
                if isLoading {
                    loadingView
                } else if let err = errorMsg {
                    errorView(err)
                } else if filtered.isEmpty {
                    emptyView
                } else {
                    designGrid
                }
            }
        }
        .background(Color.white)
        .onAppear { loadDesigns() }
    }

    // MARK: - Design grid

    private var designGrid: some View {
        ScrollView {
            // Section header
            HStack {
                Text(searchText.isEmpty ? "All designs" : "Results")
                    .font(Easel.body(13, weight: .semibold))
                    .foregroundStyle(Easel.contentFg.opacity(0.5))
                Spacer()
                Text("\(filtered.count)")
                    .font(Easel.body(13))
                    .foregroundStyle(Easel.contentFg.opacity(0.35))
            }
            .padding(.horizontal, Easel.space200)
            .padding(.top, Easel.space150)
            .padding(.bottom, Easel.space100)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filtered) { design in
                    designCard(for: design)
                }
            }
            .padding(.horizontal, Easel.space200)
            .padding(.bottom, Easel.space400)
        }
    }

    private func designCard(for design: CanvaDesign) -> some View {
        Button {
            onSelect(design)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Thumbnail — 4:3 landscape ratio, fills card
                AsyncImage(url: URL(string: design.thumbnail?.url ?? "")) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        ZStack {
                            Color(hex: "#F0EBF9")
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(Easel.primaryBg.opacity(0.6))
                        }
                    default:
                        ZStack {
                            Color(hex: "#F8F8F9")
                            ProgressView().tint(Easel.primaryBg)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(4/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: "#F3F4F7"))
                )

                // Title
                Text(design.title ?? "Untitled")
                    .font(Easel.body(12, weight: .semibold))
                    .foregroundStyle(Easel.contentFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Easel.space200) {
            Spacer()
            ProgressView().tint(Easel.primaryBg).scaleEffect(1.3)
            Text("Loading designs…")
                .font(Easel.body(14))
                .foregroundStyle(Easel.contentFg.opacity(0.5))
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: Easel.space200) {
            Spacer()
            ZStack {
                Circle().fill(Color(hex: "#FFE8E8")).frame(width: 64, height: 64)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color(hex: "#E53E3E"))
            }
            Text("Couldn't load designs")
                .font(Easel.body(17, weight: .semibold))
                .foregroundStyle(Easel.contentFg)
            Text(message)
                .font(Easel.body(13))
                .foregroundStyle(Easel.contentFg.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Easel.space400)
            Button("Try again") { loadDesigns() }
                .font(Easel.body(15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Easel.space300)
                .padding(.vertical, Easel.space150)
                .background(Easel.primaryBg, in: Capsule())
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: Easel.space200) {
            Spacer()
            ZStack {
                Circle().fill(Color(hex: "#E7DBFF")).frame(width: 72, height: 72)
                Image(systemName: searchText.isEmpty ? "rectangle.stack.badge.plus" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(Easel.primaryBg)
            }
            Text(searchText.isEmpty ? "No designs yet" : "No results for \"\(searchText)\"")
                .font(Easel.body(17, weight: .semibold))
                .foregroundStyle(Easel.contentFg)
            Text(searchText.isEmpty
                 ? "Create a design in Canva, then come back."
                 : "Try a different search term.")
                .font(Easel.body(14))
                .foregroundStyle(Easel.contentFg.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Easel.space300)
            Spacer()
        }
    }

    // MARK: - Data

    private func loadDesigns() {
        isLoading = true
        errorMsg  = nil
        Task {
            do {
                designs   = try await api.listDesigns()
            } catch {
                errorMsg  = error.localizedDescription
            }
            isLoading = false
        }
    }
}
