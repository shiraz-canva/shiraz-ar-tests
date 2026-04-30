import SwiftUI

struct DesignPickerView: View {
    @EnvironmentObject var api: CanvaAPIService
    @Environment(\.dismiss) private var dismiss

    @State private var designs:   [CanvaDesign] = []
    @State private var isLoading  = true
    @State private var errorMsg:  String?

    let onSelect: (CanvaDesign) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading your designs…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if let err = errorMsg {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(err)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { loadDesigns() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if designs.isEmpty {
                    ContentUnavailableView(
                        "No Designs Found",
                        systemImage: "rectangle.stack.badge.plus",
                        description: Text("Create a design in Canva, then come back here.")
                    )

                } else {
                    List(designs) { design in
                        Button {
                            onSelect(design)
                        } label: {
                            HStack(spacing: 14) {
                                AsyncImage(url: URL(string: design.thumbnail?.url ?? "")) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    case .failure:
                                        Image(systemName: "photo").foregroundStyle(.secondary)
                                    default:
                                        ProgressView()
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(design.title ?? "Untitled")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(design.id)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Your Designs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { loadDesigns() }
    }

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
