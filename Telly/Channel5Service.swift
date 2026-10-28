// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CommonCrypto

enum Channel5Error: LocalizedError {
    case signInRequired, message(String)
    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to Channel 5 to watch."
        case .message(let message): return message
        }
    }
}
struct Channel5Response { let data: Data; let status: Int }
/// Isolated requests: credentials never follow redirects or enter browser storage.
final class Channel5HTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = Channel5HTTP()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 18; c.timeoutIntervalForResource = 30
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return false }
        return ["cassie.channel5.com", "corona.channel5.com", "feeds-api.channel5.com", "userservice-api.channel5.com", "c5apps.channel5.com", "api-images.channel5.com"].contains(host)
    }
    static func mediaAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return false }
        return host == "dai.google.com" || host.hasSuffix(".channel5.com") || host.hasSuffix(".akamaized.net") || host.hasSuffix(".akamaihd.net")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String = "application/json; charset=utf-8", bearer: String? = nil, limit: Int = 8_000_000) async throws -> Channel5Response {
        guard Self.allowed(url) else { throw Channel5Error.message("Unexpected Channel 5 service address.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("https://www.channel5.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.channel5.com/", forHTTPHeaderField: "Referer")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let bearer {
            guard url.host == "userservice-api.channel5.com" || (url.host == "cassie.channel5.com" && (url.path.hasPrefix("/api/v2/media/") || url.path.hasPrefix("/api/v2/live_media/"))), !bearer.contains("\r"), !bearer.contains("\n") else { throw Channel5Error.message("Invalid Channel 5 account request.") }
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let r = response as? HTTPURLResponse, r.url == url, data.count <= limit else { throw Channel5Error.message("Channel 5 returned an invalid response.") }
            return Channel5Response(data: data, status: r.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let e as Channel5Error { throw e }
        catch { throw Channel5Error.message("Could not reach Channel 5 (network code \((error as NSError).code)). Please retry.") }
    }
    func data(_ url: URL) async throws -> Data {
        let r = try await send(url)
        guard r.status == 200 else { throw Channel5Error.message("Channel 5 request failed (HTTP \(r.status)). Please retry.") }
        return r.data
    }
}

/// Normal public-client metadata protocol; this never handles media/content keys.
enum Channel5Wire {
    static func base64URL(_ string: String) -> Data? {
        let s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
    static func url64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func signedURL(id: String, live: Bool, now: Date = Date()) throws -> URL {
        guard !id.isEmpty, id.count <= 80, id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { throw Channel5Error.message("Invalid Channel 5 programme.") }
        let raw = "https://cassie.channel5.com/api/v2/\(live ? "live_media" : "media")/my5desktopng/\(id).json?timestamp=\(Int(now.timeIntervalSince1970.rounded()))"
        let key = Channel5PublicMetadata.hmac
        var mac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        mac.withUnsafeMutableBytes { out in key.withUnsafeBytes { k in Data(raw.utf8).withUnsafeBytes { input in CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, key.count, input.baseAddress, raw.utf8.count, out.baseAddress) } } }
        guard let url = URL(string: raw + "&auth=" + url64(mac)) else { throw Channel5Error.message("Could not create a Channel 5 playback request.") }
        return url
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ivString = root["iv"] as? String, let value = root["data"] as? String,
              let iv = base64URL(ivString), iv.count == 16, let encrypted = base64URL(value), !encrypted.isEmpty, encrypted.count <= 4_000_000 else { throw Channel5Error.message("Channel 5's playback response could not be read.") }
        let key = Channel5PublicMetadata.aes
        var clear = Data(count: encrypted.count + 16); var written = 0
        let status = clear.withUnsafeMutableBytes { dst in key.withUnsafeBytes { k in iv.withUnsafeBytes { i in encrypted.withUnsafeBytes { src in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count, i.baseAddress, src.baseAddress, encrypted.count, dst.baseAddress, encrypted.count + 16, &written)
        } } } }
        guard status == kCCSuccess else { throw Channel5Error.message("Channel 5's playback configuration changed. Please update Telly.") }
        clear.count = written
        guard let object = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { throw Channel5Error.message("Channel 5 returned no playback details.") }
        return object
    }
    static func formValue(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
    static func fairPlayContentID(_ raw: String) throws -> String {
        guard raw.hasPrefix("skd://") else { throw Channel5Error.message("Channel 5 provided an invalid content identifier.") }
        let id = String(raw.dropFirst(6))
        guard id.count <= 160, id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { throw Channel5Error.message("Channel 5 provided an invalid content identifier.") }
        return id
    }
    static func licenceAllowed(_ url: URL) -> Bool { Channel5HTTP.allowed(url) && url.host == "cassie.channel5.com" && url.path.hasPrefix("/api/v2/licences/fairplay/") }
    static func metadata(id: String, live: Bool, session: String?) async throws -> [String: Any] {
        let response = try await Channel5HTTP.shared.send(signedURL(id: id, live: live), bearer: session)
        if response.status == 401 { throw Channel5Error.signInRequired }
        if response.status == 403 { throw Channel5Error.message("Channel 5 declined this session. Check your account and UK regional access.") }
        if response.status == 404 { throw Channel5Error.message("This Channel 5 programme is no longer available.") }
        guard response.status == 200 else { throw Channel5Error.message("Channel 5 playback request failed (HTTP \(response.status)). Please retry.") }
        return try decode(response.data)
    }
}

// Public web-client service metadata constants (player 4.8.0-19); not DRM content keys.
private enum Channel5PublicMetadata {
    static let hmac = Data(base64Encoded: "piEhXFOKU+f98IQlCyHnmA==")!
    static let aes = Data(base64Encoded: "hypN8q5/1OuQgroOcv+cqQ==")!
}
