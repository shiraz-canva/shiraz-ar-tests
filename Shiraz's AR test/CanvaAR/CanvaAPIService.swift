import Foundation
import Combine
import AuthenticationServices
import CryptoKit

/// Handles Canva Connect API authentication (OAuth 2.0 + PKCE, confidential client)
/// and design operations via the Canva Connect REST API.
/// Token exchange is handled server-side by the Vercel backend.
@MainActor
class CanvaAPIService: NSObject, ObservableObject {
    static let shared = CanvaAPIService()

    // ── Configuration ─────────────────────────────────────────────────────────
    private let clientID    = "OC-AZ3dLDxy5UuA"
    // Client secret lives only in Vercel env vars — never in the app.
    private let redirectURI = "https://canva-ar-auth.vercel.app/callback"
    private let baseURL     = "https://api.canva.com/rest/v1"
    private let authURL     = "https://www.canva.com/api/oauth/authorize"
    private let scopes      = "design:meta:read design:content:read"

    // ── State ──────────────────────────────────────────────────────────────────
    @Published var isAuthenticated = false
    @Published var accessToken: String?
    @Published var authError: String?

    // MARK: - Auth

    func signIn() async {
        do {
            // Generate PKCE pair — Canva requires code_challenge even for confidential clients
            let verifier  = generateCodeVerifier()
            let challenge = generateCodeChallenge(from: verifier)

            // Use URLComponents so query values (especially redirect_uri) are
            // percent-encoded correctly — manual encoding with .urlQueryAllowed
            // leaves ':' and '/' unencoded inside values, which causes invalid_request.
            var components = URLComponents(string: authURL)!
            components.queryItems = [
                URLQueryItem(name: "response_type",         value: "code"),
                URLQueryItem(name: "client_id",             value: clientID),
                URLQueryItem(name: "redirect_uri",          value: redirectURI),
                URLQueryItem(name: "scope",                 value: scopes),
                URLQueryItem(name: "code_challenge",        value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state",                 value: verifier),
            ]
            guard let authorizationURL = components.url else { throw APIError.authFailed }

            let token = try await presentAuthSession(url: authorizationURL)
            self.accessToken     = token
            self.isAuthenticated = true
        } catch {
            authError = error.localizedDescription
        }
    }

    private func presentAuthSession(url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "canvaar"
            ) { callbackURL, error in
                if let error = error { cont.resume(throwing: error); return }
                guard
                    let cbURL  = callbackURL,
                    let items  = URLComponents(url: cbURL, resolvingAgainstBaseURL: false)?.queryItems
                else {
                    cont.resume(throwing: APIError.authFailed); return
                }
                if let err = items.first(where: { $0.name == "error" })?.value {
                    let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
                    cont.resume(throwing: APIError.authError(desc.isEmpty ? err : "\(err): \(desc)")); return
                }
                guard let token = items.first(where: { $0.name == "access_token" })?.value else {
                    cont.resume(throwing: APIError.authFailed); return
                }
                cont.resume(returning: token)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }
    }

    // MARK: - Designs

    func listDesigns() async throws -> [CanvaDesign] {
        let data = try await get(path: "/designs")
        return try JSONDecoder().decode(DesignListResponse.self, from: data).items
    }

    // MARK: - Export

    /// Exports a design as a PNG and returns the download URL.
    /// Uses async polling (max 30 attempts, 1 s apart).
    func exportDesign(id: String) async throws -> URL {
        // Canva Connect API: POST /v1/exports with design_id in the body
        struct ExportBody: Encodable {
            struct Format: Encodable { let type: String }
            let design_id: String
            let format: Format
        }
        let body = try JSONEncoder().encode(ExportBody(design_id: id, format: .init(type: "png")))
        let startData = try await post(path: "/exports", body: body)

        if let raw = String(data: startData, encoding: .utf8) {
            print("📦 Export start response: \(raw)")
        }

        let startResp = try JSONDecoder().decode(ExportStartResponse.self, from: startData)
        guard let jobID = startResp.job.id else { throw APIError.exportDetail("Job started but no job ID returned") }
        return try await pollExport(jobID: jobID)
    }

    private func pollExport(jobID: String, attempt: Int = 0) async throws -> URL {
        guard attempt < 30 else { throw APIError.exportTimeout }

        let data = try await get(path: "/exports/\(jobID)")

        if let raw = String(data: data, encoding: .utf8) {
            print("🔄 Export poll [\(attempt)]: \(raw)")
        }

        let status = try JSONDecoder().decode(ExportStatusResponse.self, from: data)

        switch status.job.status {
        case "success":
            guard let urlStr = status.job.urls?.first else {
                throw APIError.exportDetail("Job succeeded but urls array is empty")
            }
            guard let url = URL(string: urlStr) else {
                throw APIError.exportDetail("Invalid download URL: \(urlStr)")
            }
            return url
        case "failed":
            throw APIError.exportDetail("Canva export job status: failed")
        default:
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await pollExport(jobID: jobID, attempt: attempt + 1)
        }
    }

    // MARK: - HTTP Helpers

    private func get(path: String) async throws -> Data {
        guard let token = accessToken else { throw APIError.notAuthenticated }
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let raw = String(data: data, encoding: .utf8),
           let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            print("❌ GET \(path) → \(http.statusCode): \(raw)")
            throw APIError.exportFailed
        }
        return data
    }

    private func post(path: String, body: Data) async throws -> Data {
        guard let token = accessToken else { throw APIError.notAuthenticated }
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        if let sent = String(data: body, encoding: .utf8) {
            print("📤 POST \(path) body: \(sent)")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let raw  = String(data: data, encoding: .utf8) ?? ""
        print("📥 POST \(path) → \(code): \(raw)")
        if code >= 400 {
            throw APIError.exportDetail("POST \(path) → HTTP \(code): \(raw)")
        }
        return data
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buf = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        return Data(buf).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    // MARK: - Errors

    enum APIError: LocalizedError {
        case authFailed, authError(String), notAuthenticated, exportFailed, exportDetail(String), exportTimeout

        var errorDescription: String? {
            switch self {
            case .authFailed:            return "Authentication failed."
            case .authError(let msg):    return "Auth error: \(msg)"
            case .notAuthenticated:      return "Not signed in."
            case .exportFailed:          return "Design export failed."
            case .exportDetail(let msg): return "Export: \(msg)"
            case .exportTimeout:         return "Export timed out — try again."
            }
        }
    }
}

// MARK: - ASWebAuthentication context

extension CanvaAPIService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - Base64URL

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
