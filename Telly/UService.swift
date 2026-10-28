// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum UError: LocalizedError {
    case signInRequired
    case message(String)
    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to U to watch this programme."
        case .message(let text): return text
        }
    }
}
struct UResponse { let data: Data; let status: Int }
final class UHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = UHTTP()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        return URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }()
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        switch url.host {
        case "tvlogin.uktvapi.co.uk": return ["/get_code","/check_code"].contains(url.path)
        case "players.brightcove.net": return url.path == "/1242911124001/0RyQs9qPh_default/config.json"
        case "edge.api.brightcove.com": return url.path.hasPrefix("/playback/v1/accounts/1242911124001/videos/")
        case "manifest.prod.boltdns.net": return url.path.hasPrefix("/license/v1/fairplay/1242911124001/") || url.path == "/license/v1/fairplay_app_cert/1242911124001"
        default: return false
        }
    }
    static func mediaAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host else { return false }
        return host == "manifest.prod.boltdns.net" || host == "uktv.brightcovecdn.com" || host.hasSuffix(".akamaized.net") || host.hasSuffix(".akamaihd.net")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ url: URL, method: String = "GET", body: Data? = nil, policy: String? = nil, limit: Int = 4_000_000) async throws -> UResponse {
        guard Self.allowed(url) else { throw UError.message("Unexpected U service address.") }
        var request = URLRequest(url:url); request.httpMethod = method; request.httpBody = body
        request.setValue("https://u.co.uk",forHTTPHeaderField:"Origin")
        request.setValue("https://u.co.uk/",forHTTPHeaderField:"Referer")
        request.setValue("U/2.0.16 (Apple TV)",forHTTPHeaderField:"User-Agent")
        request.setValue(body == nil ? "application/json" : "application/octet-stream",forHTTPHeaderField:"Accept")
        if body != nil { request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if let policy {
            guard url.host == "edge.api.brightcove.com", policy.count < 8192, !policy.contains("\r"), !policy.contains("\n") else { throw UError.message("Invalid U player configuration.") }
            request.setValue("application/json;pk=" + policy,forHTTPHeaderField:"Accept")
        }
        do {
            let (data,response) = try await session.data(for:request); try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == url, data.count <= limit else { throw UError.message("U returned an invalid response.") }
            return UResponse(data:data,status:response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as UError { throw error }
        catch { throw UError.message("Could not reach U (network code \((error as NSError).code)). Please retry.") }
    }
}

enum UPlaybackWire {
    static let playerConfigURL = URL(string:"https://players.brightcove.net/1242911124001/0RyQs9qPh_default/config.json")!
    static func videoURL(_ id: String) throws -> URL {
        guard id.range(of:#"^[0-9]{1,20}$"#,options:.regularExpression) != nil else { throw UError.message("Invalid U episode.") }
        return URL(string:"https://edge.api.brightcove.com/playback/v1/accounts/1242911124001/videos/" + id)!
    }
    static func policy(_ data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let cloud = root["video_cloud"] as? [String:Any], let value = cloud["policy_key"] as? String,
              !value.isEmpty, value.count < 8192, !value.contains("\r"), !value.contains("\n") else { throw UError.message("U’s player configuration could not be loaded.") }
        return value
    }
    static func fairPlay(_ data: Data, id: String, now: Date = Date()) throws -> (URL,URL,UFairPlayConfig) {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], root["id"] as? String == id,
              let sources = root["sources"] as? [[String:Any]] else { throw UError.message("U’s playback response has changed. Please retry.") }
        for source in sources {
            guard source["type"] as? String == "application/x-mpegURL",
                  let raw = source["src"] as? String, let manifest = URL(string:raw), UHTTP.mediaAllowed(manifest),
                  let systems = source["key_systems"] as? [String:Any], let fps = systems["com.apple.fps.1_0"] as? [String:Any],
                  let certificateString = fps["certificate_url"] as? String, let certificate = URL(string:certificateString), UHTTP.allowed(certificate),
                  certificate.path == "/license/v1/fairplay_app_cert/1242911124001",
                  let licenceString = fps["key_request_url"] as? String, let licence = URL(string:licenceString), UHTTP.allowed(licence),
                  licence.path.hasPrefix("/license/v1/fairplay/1242911124001/") else { continue }
            return (manifest,certificate,UFairPlayConfig(licence:licence,videoID:id,created:now))
        }
        throw UError.message("U did not offer a supported Apple TV stream for this episode.")
    }
    static func contentID(_ raw: String) throws -> String {
        guard raw.hasPrefix("skd://"), raw.count > 6, raw.count <= 2048,
              !raw.contains("\r"), !raw.contains("\n"), !raw.contains("\0") else { throw UError.message("U returned an invalid protected-stream identifier.") }
        // Brightcove's published FairPlay client uses the full suffix after //.
        return String(raw.dropFirst(6))
    }
    static func licenceBody(spc: Data, contentID: String) throws -> Data {
        guard !spc.isEmpty else { throw UError.message("Could not create U’s FairPlay challenge.") }
        var body: [String:Any] = ["server_playback_context":spc.base64EncodedString()]
        let components = contentID.components(separatedBy:"/")
        if components.count > 3 { body["key_id"] = components[3] }
        return try JSONSerialization.data(withJSONObject:body)
    }
}
