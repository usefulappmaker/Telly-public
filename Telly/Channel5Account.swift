// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

struct Channel5Pairing {
    let pin: String
    let secret: String
    let revision: UUID
    let expires: Date
    var activationURL: URL { URL(string: "https://activate.channel5.com/?pin=" + pin)! }
}
/// A successful pairing creates an account session (HTTP 201). The initial
/// waiting response is HTTP 204; accepting only 200 loses a completed sign-in.
enum Channel5PairingResponse {
    static func session(from response: Channel5Response) throws -> String? {
        if response.status == 204 { return nil }
        if response.status == 404 || response.status == 410 { throw Channel5Error.message("This sign-in code has expired. Get a new code.") }
        guard response.status == 200 || response.status == 201 else { throw Channel5Error.message("Channel 5 sign-in could not be checked (HTTP \(response.status)). Please retry.") }
        let root = try? JSONSerialization.jsonObject(with: response.data, options: .fragmentsAllowed)
        let dict = root as? [String: Any]
        let token = dict?["sessionId"] as? String ?? dict?["sessionToken"] as? String ?? root as? String
        guard let token, !token.isEmpty, token.count < 16384, !token.contains("\r"), !token.contains("\n") else { throw Channel5Error.message("Channel 5 returned an unexpected sign-in response. Please retry.") }
        return token
    }
}
actor Channel5AccountService {
    static let shared = Channel5AccountService()
    private var loaded = false
    private var session: String?
    private var revision = UUID()
    private let http = Channel5HTTP.shared
    private static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"org.tellyplayer.channel5", kSecAttrAccount as String:"session-v1"] }
    private func load() throws {
        guard !loaded else { return }
        var q = Self.query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Channel5Error.message("Could not read Channel 5 sign-in from Keychain.") }
        session = (value as? Data).flatMap { String(data:$0,encoding:.utf8) }; loaded = true
    }
    func isSignedIn() throws -> Bool { try load(); return session != nil }
    func token() throws -> String { try load(); guard let session else { throw Channel5Error.signInRequired }; return session }
    func signOut() throws {
        revision = UUID()
        let status = SecItemDelete(Self.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Channel5Error.message("Could not remove Channel 5 sign-in.") }
        session = nil; loaded = true
    }
    func newCode() async throws -> Channel5Pairing {
        revision = UUID(); let id = revision
        let r = try await http.send(URL(string:"https://userservice-api.channel5.com/activationPins")!,method:"POST",body:Data("{}".utf8))
        try Task.checkCancellation()
        guard revision == id else { throw CancellationError() }
        guard r.status == 201, let root = try JSONSerialization.jsonObject(with:r.data) as? [String:Any],
              let pin = root["pin"] as? String, pin.range(of:#"^[A-Za-z0-9]{6}$"#,options:.regularExpression) != nil,
              let secret = root["pinSecret"] as? String, !secret.isEmpty, secret.count <= 16384 else { throw Channel5Error.message("Could not get a Channel 5 sign-in code. Please retry.") }
        return Channel5Pairing(pin:pin,secret:secret,revision:id,expires:Date().addingTimeInterval(600))
    }
    func check(_ pairing: Channel5Pairing) async throws -> Bool {
        guard revision == pairing.revision else { throw CancellationError() }
        guard Date() < pairing.expires else { throw Channel5Error.message("This sign-in code has expired. Get a new code.") }
        let url = URL(string:"https://userservice-api.channel5.com/activationPins/\(pairing.pin)/poll?longPoll=false")!
        let response = try await http.send(url,bearer:pairing.secret,limit:128000)
        try Task.checkCancellation()
        guard revision == pairing.revision else { throw CancellationError() }
        guard let token = try Channel5PairingResponse.session(from: response) else { return false }
        // Validate the paired session before saving it; never accept the PIN secret as a login.
        let user = try await http.send(URL(string:"https://userservice-api.channel5.com/user/info")!,bearer:token,limit:256000)
        try Task.checkCancellation()
        guard revision == pairing.revision else { throw CancellationError() }
        guard user.status == 200 else { throw Channel5Error.message("Channel 5 did not confirm this account session. Get a new code.") }
        let attrs: [String:Any] = [kSecValueData as String:Data(token.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(Self.query as CFDictionary,attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = Self.query; attrs.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw Channel5Error.message("Could not save Channel 5 sign-in securely.") }
        } else if status != errSecSuccess { throw Channel5Error.message("Could not save Channel 5 sign-in securely.") }
        session = token; loaded = true; return true
    }
    func cancel(_ pairing: Channel5Pairing) { if revision == pairing.revision { revision = UUID() } }
}
