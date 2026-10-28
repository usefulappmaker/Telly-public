// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

enum ITVAccountError: LocalizedError {
    case signInRequired, message(String)
    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to ITV to watch its live channels."
        case .message(let text): return text
        }
    }
}
struct ITVHTTPResponse { let data: Data; let status: Int }
typealias ITVTransport = @Sendable (URLRequest) async throws -> ITVHTTPResponse

/// No shared browser cookies, disk cache or redirects carrying account credentials.
final class ITVAccountHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 18; config.timeoutIntervalForResource = 25
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ request: URLRequest) async throws -> ITVHTTPResponse {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              ["auth.prd.user.itv.com", "simulcast.itv.com", "stream-starter.fastly.ottstream.itv.com"].contains(url.host ?? "") else {
            throw ITVAccountError.message("Unexpected ITV account destination.")
        }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url?.host == url.host, data.count <= 2 * 1024 * 1024 else {
                throw ITVAccountError.message("ITV returned an invalid response.")
            }
            return ITVHTTPResponse(data: data, status: response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ITVAccountError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            // URLSession errors can include refresh-token query strings.
            throw ITVAccountError.message("Could not reach ITV (network code \((error as NSError).code)). Please retry.")
        }
    }
}
struct ITVCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    static func token(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.count < 32768,
              !value.contains("\n"), !value.contains("\r") else { return nil }; return value
    }
    // Claims guide renewal timing only. ITV validates all tokens and entitlements.
    static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: "."); guard parts.count == 3 else { return [:] }
        var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let data = Data(base64Encoded: raw) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    static func parse(_ data: Data, previousRefresh: String? = nil, now: Date = Date()) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = token(root["access_token"]), let refresh = token(root["refresh_token"]) ?? previousRefresh else {
            throw ITVAccountError.message("ITV returned an incomplete account session. Please sign in again.")
        }
        let expiry = (claims(access)["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? (root["expires_in"] as? Double).map { now.addingTimeInterval($0) } ?? now.addingTimeInterval(900)
        guard expiry > now else { throw ITVAccountError.signInRequired }
        return Self(accessToken: access, refreshToken: refresh, expiresAt: expiry)
    }
}
struct ITVAccountVault: @unchecked Sendable {
    var read: @Sendable () throws -> ITVCredentials?
    var write: @Sendable (ITVCredentials) throws -> Void
    var remove: @Sendable () throws -> Void
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.example.Telly.itv-account", kSecAttrAccount as String: "session-v1"]
    }
    static let device = Self(read: {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ITVAccountError.message("Could not read ITV sign-in from Keychain.") }
        return try JSONDecoder().decode(ITVCredentials.self, from: data)
    }, write: { value in
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ITVAccountError.message("Could not save ITV sign-in in Keychain.") }; return
        }
        guard status == errSecSuccess else { throw ITVAccountError.message("Could not update ITV sign-in in Keychain.") }
    }, remove: {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ITVAccountError.message("Could not remove ITV sign-in from Keychain.") }
    })
}

actor ITVAccountService {
    static let shared = ITVAccountService()
    private let transport: ITVTransport
    private let vault: ITVAccountVault
    private var credentials: ITVCredentials?
    private var loaded = false
    private var revision = UUID()
    private var refreshing: (UUID, Task<ITVCredentials, Error>)?
    init(transport: ITVTransport? = nil, vault: ITVAccountVault = .device) {
        let http = ITVAccountHTTP()
        self.transport = transport ?? { try await http.send($0) }; self.vault = vault
    }
    private func load() throws {
        if !loaded { credentials = try vault.read(); loaded = true }
    }
    func isSignedIn() throws -> Bool { try load(); return credentials != nil }
    func signOut() throws {
        // Invalidate in-flight requests before they can resurrect a signed-out session.
        revision = UUID(); refreshing?.1.cancel(); refreshing = nil
        credentials = nil; loaded = true; try vault.remove()
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url); request.timeoutInterval = 18
        request.setValue("application/vnd.user.auth.v2+json", forHTTPHeaderField: "Accept")
        request.setValue("https://app.10ft.itv.com/", forHTTPHeaderField: "Referer")
        return request
    }
    func newCode() async throws -> String {
        let response = try await transport(Self.request(URL(string: "https://auth.prd.user.itv.com/generate/code")!))
        try Task.checkCancellation()
        guard response.status == 200, let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let code = root["code"] as? String, code.range(of: "^[0-9]{6,10}$", options: .regularExpression) != nil else {
            throw ITVAccountError.message("ITV could not issue a sign-in code. Please try again.")
        }; return code
    }
    private static func exchange(_ refresh: String, transport: ITVTransport) async throws -> ITVCredentials {
        var parts = URLComponents(string: "https://auth.prd.user.itv.com/token")!
        parts.queryItems = [URLQueryItem(name: "refresh", value: refresh)]
        let response = try await transport(request(parts.url!)); try Task.checkCancellation()
        if response.status == 400 || response.status == 401 || response.status == 403 { throw ITVAccountError.signInRequired }
        guard response.status == 200 else { throw ITVAccountError.message("ITV account renewal failed (HTTP \(response.status)). Please retry.") }
        return try ITVCredentials.parse(response.data, previousRefresh: refresh)
    }
    /// ITV's own TV web app reads verify.data.token, then exchanges it at /token?refresh=.
    func checkCode(_ code: String) async throws -> Bool {
        guard code.range(of: "^[0-9]{6,10}$", options: .regularExpression) != nil else { throw ITVAccountError.message("Invalid ITV sign-in code.") }
        let generation = revision
        let response = try await transport(Self.request(URL(string: "https://auth.prd.user.itv.com/verify/\(code)")!))
        try Task.checkCancellation()
        if response.status == 404 || response.status == 204 { return false }
        guard response.status == 200, let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let refresh = ITVCredentials.token(root["token"]) else { throw ITVAccountError.message("ITV could not verify this sign-in code. Please request a new code.") }
        let session = try await Self.exchange(refresh, transport: transport)
        try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
        try vault.write(session); credentials = session; loaded = true; revision = UUID()
        return true
    }
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        try load(); guard let old = credentials else { throw ITVAccountError.signInRequired }
        if !forceRefresh, old.expiresAt.timeIntervalSinceNow > 90 { return old.accessToken }
        let generation = revision
        let work: (UUID, Task<ITVCredentials, Error>)
        if let refreshing { work = refreshing }
        else {
            let transport = self.transport
            work = (UUID(), Task { try await Self.exchange(old.refreshToken, transport: transport) }); refreshing = work
        }
        do {
            let value = try await work.1.value
            try Task.checkCancellation(); guard revision == generation else { throw CancellationError() }
            if refreshing?.0 == work.0 { try vault.write(value); credentials = value; refreshing = nil }
            return value.accessToken
        } catch {
            if refreshing?.0 == work.0 {
                refreshing = nil
                if case ITVAccountError.signInRequired = error { try signOut() }
            }
            throw error
        }
    }
    func liveURL(channel: LiveChannel, osVersion: String, model: String) async throws -> URL {
        guard channel.provider == .itv, let endpoint = channel.itvPlaylistURL else { throw ITVAccountError.message("Missing ITV live channel address.") }
        _ = try ITVLiveAPI.endpoint(endpoint, channelID: String(channel.id.dropFirst(4)))
        var token = try await accessToken()
        let generation = revision
        for attempt in 0...1 {
            var request = Self.request(endpoint); request.httpMethod = "POST"
            request.setValue("application/vnd.itv.online.playlist.sim.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ITVLiveAPI.requestBody(token: token, osVersion: osVersion, model: model))
            let response = try await transport(request); try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            if response.status == 401 {
                if attempt == 0 { token = try await accessToken(forceRefresh: true); continue }
                try signOut(); throw ITVAccountError.signInRequired
            }
            if response.status == 403 { throw ITVAccountError.message("ITV cannot play this channel for your account or location. Check your ITV account region and try another channel.") }
            guard response.status == 200 else { throw ITVAccountError.message("ITV live playback is unavailable (HTTP \(response.status)). Please try another channel.") }
            return try ITVLiveAPI.playbackURL(from: response.data)
        }
        throw ITVAccountError.signInRequired
    }
}
