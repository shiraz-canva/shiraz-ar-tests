import Foundation
import Combine
import AuthenticationServices
import CryptoKit

/// Handles Canva Connect API authentication (OAuth 2.0 + PKCE) and design operations.
/// Replace `clientID` with your Canva app's client ID from the Developer Portal.
@MainActor
class CanvaAPIService: NSObject, ObservableObject {
    static let shared = CanvaAPIService()

    // ── Configuration ─────────────────────────────────────────────────────────
    private let clientID     = "OC-AZ3dLDxy5UuA"
    // HTTPS relay hosted on GitHub Pages — required by Canva Connect API.
    // This page forwards the OAuth code back into the app via canvaar:// deep link.
    // See oauth-relay/index.html — deploy to: https://shiraz-canva.github.io/shiraz-ar-tests/
    private let redirectURI  = "canva-ar-auth.vercel.app/callback"
    private let baseURL   = "https://api.canva.com/rest/v1"
    private let authURL   = "https://www.canva.com/api/oauth/authorize"
    private let tokenURL  = "https://api.canva.com/rest/v1/oauth/token"
    private let scopes    = "design:meta:read design:content:read asset:read"

    // ── State ──────────────────────────────────────────────────────────────────
    @Published var isAuthenticated = false
    @Published var accessToken: String?
    @Published var authError: String?

    private var codeVerifier: String?

    // MARK: - Auth

    func signIn() async {
        do {
            let verifier   = generateCodeVerifier()
            codeVerifier   = verifier
            let challenge  = generateCodeChallenge(from: verifier)

            var components = URLComponents(string: authURL)!
            components.queryItems = [
                .init(name: "response_type",          value: "code"),
                .init(name: "client_id",              value: clientID),
                
                .init(name: "scope",                  value: scopes),
                .init(name: "code_challenge",         value: challenge),
                .init(name: "code_challenge_method",  value: "S256"),
                .init(name: "state",                  value: UUID().uuidString)
            ]

            let code = try await presentAuthSession(url: components.url!)
            try await exchangeCode(code)
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
                    let cbURL = callbackURL,
                    let code  = URLComponents(url: cbURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    cont.resume(throwing: APIError.authFailed); return
                }
                cont.resume(returning: code)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }
    }

    private func exchangeCode(_ code: String) async throws {
        guard let verifier = codeVerifier else { throw APIError.authFailed }

        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type":    "authorization_code",
            "code":          code,
            "redirect_uri":  redirectURI,
            "client_id":     clientID,
            "code_verifier": verifier
        ]
        req.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken     = token.access_token
        isAuthenticated = true
    }

    // MARK: - Designs

    func listDesigns() async throws -> [CanvaDesign] {
        let data = try await get(path: "/designs")
        return try JSONDecoder().decode(DesignListResponse.self, from: data).items
    }

    // MARK: - Export

    /// Exports a design as a PNG and returns the download URL.
    /// Uses async polling (max 20 attempts, 1 s apart).
    func exportDesign(id: String) async throws -> URL {
        let body = try JSONEncoder().encode(["format": "png"])
        let startData = try await post(path: "/designs/\(id)/exports", body: body)
        let startResp = try JSONDecoder().decode(ExportStartResponse.self, from: startData)
        guard let jobID = startResp.job.id else { throw APIError.exportFailed }
        return try await pollExport(jobID: jobID)
    }

    private func pollExport(jobID: String, attempt: Int = 0) async throws -> URL {
        guard attempt < 20 else { throw APIError.exportTimeout }

        let data   = try await get(path: "/exports/\(jobID)")
        let status = try JSONDecoder().decode(ExportStatusResponse.self, from: data)

        switch status.job.status {
        case "success":
            guard
                let urlStr = status.job.pages?.first?.download_url,
                let url    = URL(string: urlStr)
            else { throw APIError.exportFailed }
            return url
        case "failed":
            throw APIError.exportFailed
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
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func post(path: String, body: Data) async throws -> Data {
        guard let token = accessToken else { throw APIError.notAuthenticated }
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
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
        case authFailed, notAuthenticated, exportFailed, exportTimeout

        var errorDescription: String? {
            switch self {
            case .authFailed:        return "Authentication failed."
            case .notAuthenticated:  return "Not signed in."
            case .exportFailed:      return "Design export failed."
            case .exportTimeout:     return "Export timed out — try again."
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
