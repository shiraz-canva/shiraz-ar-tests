import Foundation

// MARK: - Canva API Models

struct CanvaDesign: Identifiable, Decodable {
    let id: String
    let title: String?
    let thumbnail: Thumbnail?

    struct Thumbnail: Decodable {
        let url: String
        let width: Int?
        let height: Int?
    }
}

struct DesignListResponse: Decodable {
    let items: [CanvaDesign]
    let continuation: String?
}

struct ExportStartResponse: Decodable {
    let job: JobStart

    struct JobStart: Decodable {
        let id: String?
        let status: String
    }
}

struct ExportStatusResponse: Decodable {
    let job: JobDetail

    struct JobDetail: Decodable {
        let id: String?
        let status: String
        let urls: [String]?   // Canva returns a flat string array, not pages objects
    }
}

// MARK: - Print Formats

struct PrintFormat: Identifiable, Hashable {
    let id: String
    let name: String
    let widthM: Float
    let heightM: Float
    let icon: String
    let suggestedMode: PlacementMode

    var displayDimensions: String {
        let w = Int(widthM * 100), h = Int(heightM * 100)
        return "\(w)×\(h)cm"
    }

    static let all: [PrintFormat] = [
        PrintFormat(id: "a4",        name: "A4",        widthM: 0.210, heightM: 0.297, icon: "doc.richtext",                        suggestedMode: .flat),
        PrintFormat(id: "a3",        name: "A3",        widthM: 0.297, heightM: 0.420, icon: "doc.richtext",                        suggestedMode: .flat),
        PrintFormat(id: "a2",        name: "A2",        widthM: 0.420, heightM: 0.594, icon: "doc.richtext.fill",                   suggestedMode: .flat),
        PrintFormat(id: "a1",        name: "A1",        widthM: 0.594, heightM: 0.841, icon: "doc.richtext.fill",                   suggestedMode: .flat),
        PrintFormat(id: "canvas",    name: "Canvas",    widthM: 0.400, heightM: 0.400, icon: "square.stack.3d.forward.dottedline",  suggestedMode: .canvas),
        PrintFormat(id: "yard_sign", name: "Yard Sign", widthM: 0.600, heightM: 0.450, icon: "rectangle.fill",                     suggestedMode: .flat),
        PrintFormat(id: "banner",    name: "Banner",    widthM: 0.850, heightM: 2.000, icon: "rectangle.portrait.fill",             suggestedMode: .banner),
        PrintFormat(id: "billboard", name: "Billboard", widthM: 1.200, heightM: 0.800, icon: "signpost.right.fill",                 suggestedMode: .billboard),
    ]
}

struct TokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int?
}

// MARK: - Placement Mode

enum PlacementMode: String, CaseIterable {
    case flat      = "Flat"
    case mug       = "Mug"
    case tshirt    = "T-Shirt"
    case phoneCase = "Phone"
    case frame     = "Frame"
    case canvas    = "Canvas"
    case banner    = "Banner"    // floor-standing retractable banner
    case billboard = "Billboard" // large floor-standing outdoor billboard

    var icon: String {
        switch self {
        case .flat:      return "rectangle.on.rectangle"
        case .mug:       return "cup.and.saucer"
        case .tshirt:    return "tshirt"
        case .phoneCase: return "iphone"
        case .frame:     return "photo.artframe"
        case .canvas:    return "square.stack.3d.forward.dottedline"
        case .banner:    return "rectangle.portrait.fill"
        case .billboard: return "signpost.right.fill"
        }
    }

    var placementHint: String {
        switch self {
        case .flat:      return "Tap a surface to place"
        case .mug:       return "Tap a surface to place"
        case .tshirt:    return "Tap your chest to place 👕"
        case .phoneCase: return "Tap a surface to place"
        case .frame:     return "Scan then tap a wall 🖼️"
        case .canvas:    return "Scan then tap a wall 🎨"
        case .banner:    return "Tap the floor to place 🪧"
        case .billboard: return "Tap the floor to place 🏙️"
        }
    }

    var prefersWall: Bool {
        self == .frame || self == .canvas
    }

    /// Floor-standing upright objects — prefer horizontal plane raycasts
    var prefersFloor: Bool {
        self == .banner || self == .billboard
    }
}
