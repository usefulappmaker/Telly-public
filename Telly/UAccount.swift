// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

struct UCredentials: Codable, Sendable {
    let accountID: String
    let sessionToken: String
    let expiresAt: Date
    static func parse(_ data: Data, now: Date = Date()) throws -> UCredentials {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let identifier = UCatalogueAPI.stringID(root["int_mpp_id"]),
              let token = root["mpp_session_token"] as? String, token.count >= 16, token.count <= 8192,
              !token.contains("\r"), !token.contains("\n"),
              let rawExpiry = root["long_session_expiry"] as? String else { throw UError.message("U returned an incomplete account session. Get a new code.") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        guard let expiry = formatter.date(from:rawExpiry) ?? ISO8601DateFormatter().date(from:rawExpiry), expiry > now else { throw UError.signInRequired }
        // Do not retain the age, gender or name returned by the pairing service.
        return UCredentials(accountID:identifier,sessionToken:token,expiresAt:expiry)
    }
}
struct UPairing: Sendable {
    let code: String
    let matchCode: String
    let revision: UUID
    let expiresAt: Date
    var activationURL: URL { URL(string:"https://u.co.uk/activate?code=" + code)! }
    static func parse(_ data: Data, revision: UUID, now: Date = Date()) throws -> UPairing {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let code = root["code"] as? String, code.range(of:#"^[A-Za-z0-9]{5}$"#,options:.regularExpression) != nil,
              let match = root["match_code"] as? String, UUID(uuidString:match) != nil else { throw UError.message("Could not get a U sign-in code. Please retry.") }
        return UPairing(code:code.uppercased(),matchCode:match,revision:revision,expiresAt:now.addingTimeInterval(1800))
    }
    var checkURL: URL {
        var url = URLComponents(string:"https://tvlogin.uktvapi.co.uk/check_code")!
        url.queryItems = [URLQueryItem(name:"code",value:code),URLQueryItem(name:"match_code",value:matchCode)]
        return url.url!
    }
}
struct UAccountVault: @unchecked Sendable {
    var read: @Sendable () throws -> UCredentials?
    var write: @Sendable (UCredentials) throws -> Void
    var remove: @Sendable () throws -> Void
    private static var query: [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.tellyplayer.u",kSecAttrAccount as String:"session-v1"] }
    static let device = Self(read: {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw UError.message("Could not read U sign-in from Keychain.") }
        return try JSONDecoder().decode(UCredentials.self,from:data)
    },write: { credentials in
        let attributes: [String:Any] = [kSecValueData as String:try JSONEncoder().encode(credentials),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw UError.message("Could not save U sign-in securely.") }
        } else if status != errSecSuccess { throw UError.message("Could not update U sign-in securely.") }
    },remove: {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UError.message("Could not remove U sign-in.") }
    })
}
actor UAccountService {
    static let shared = UAccountService()
    typealias Fetch = @Sendable (URL) async throws -> UResponse
    private let vault: UAccountVault
    private let fetch: Fetch
    private var credentials: UCredentials?
    private var loaded = false
    private var revision = UUID()
    init(vault: UAccountVault = .device, fetch: @escaping Fetch = { try await UHTTP.shared.send($0,limit:256000) }) { self.vault = vault; self.fetch = fetch }
    private func load() throws {
        guard !loaded else { return }; credentials = try vault.read(); loaded = true
    }
    func isSignedIn(now: Date = Date()) throws -> Bool {
        try load()
        if let credentials, credentials.expiresAt <= now { try signOut(); return false }
        return credentials != nil
    }
    func session(now: Date = Date()) throws -> UCredentials {
        guard try isSignedIn(now:now), let credentials else { throw UError.signInRequired }
        return credentials
    }
    func signOut() throws { revision = UUID(); try vault.remove(); credentials = nil; loaded = true }
    func newCode() async throws -> UPairing {
        revision = UUID(); let id = revision
        let response = try await fetch(URL(string:"https://tvlogin.uktvapi.co.uk/get_code")!)
        try Task.checkCancellation(); guard revision == id else { throw CancellationError() }
        guard response.status == 200 else { throw UError.message("U sign-in could not start (HTTP \(response.status)). Please retry.") }
        return try UPairing.parse(response.data,revision:id)
    }
    func check(_ pairing: UPairing, now: Date = Date()) async throws -> Bool {
        guard pairing.revision == revision else { throw CancellationError() }
        guard now < pairing.expiresAt else { throw UError.message("This U code has expired. Get a new code.") }
        let response = try await fetch(pairing.checkURL)
        try Task.checkCancellation(); guard pairing.revision == revision else { throw CancellationError() }
        if response.status == 404,
           let root = try? JSONSerialization.jsonObject(with:response.data) as? [String:Any],
           root["error"] as? String == "No user details found for code pair" { return false }
        guard response.status == 200 else { throw UError.message("U sign-in could not be checked (HTTP \(response.status)). Please retry.") }
        let value = try UCredentials.parse(response.data,now:now)
        try vault.write(value); credentials = value; loaded = true; return true
    }
    func cancel(_ pairing: UPairing) { if pairing.revision == revision { revision = UUID() } }
}
