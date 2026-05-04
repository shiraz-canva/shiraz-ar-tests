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
        let urls: [String]?
    }
}


    struct JobDetail: Decodable {
        let id: String?
        let status: String
        let pages: [Page]?

        struct Page: Decodable {
            let download_url: String?
        }
    }

struct TokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int?
}

// MARK: - Placement Mode

enum PlacementMode: String, CaseIterable {
    case flat = "Flat Surface"
    case mug = "Mug Mockup"
    case tshirt = "T-Shirt Mockup"
    case phoneCase = "Phone Case"

    var icon: String {
        switch self {
        case .flat: return "rectangle.on.rectangle"
        case .mug: return "cup.and.saucer"
        case .tshirt: return "tshirt"
        case .phoneCase: return "iphone"
        }
    }
}
