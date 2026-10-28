// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import CommonCrypto

private final class Channel4RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Channel4HTTP.allowed(url), task.originalRequest?.httpMethod != "POST" else { completionHandler(nil); return }
        completionHandler(request)
    }
}

/// Independent session: never imports Safari cookies or persists playback URLs.
final class Channel4HTTP: @unchecked Sendable {
    static let shared = Channel4HTTP()
    private let session: URLSession
    private let redirects = Channel4RedirectPolicy()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 18; config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, let host = url.host else { return false }
        return host == "www.channel4.com" || host == "all4nav.channel4.com" || host == "subs.channel4.com" || host == "static.channel4.com" || host == "keys.c4.aws.redbeemedia.com" || host == "ak-jos-c4assets-com.akamaized.net" || host == "c4assets.com" || host.hasSuffix(".c4assets.com") || host.hasSuffix(".yospace.com")
    }
    func data(_ url: URL, body: Data? = nil, limit: Int = 8_000_000, unavailableMessage: String? = nil) async throws -> Data {
        guard Self.allowed(url) else { throw BBCError.message("Unexpected Channel 4 service address.") }
        var request = URLRequest(url: url)
        request.setValue("https://www.channel4.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.channel4.com/", forHTTPHeaderField: "Referer")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let r = response as? HTTPURLResponse, let final = r.url, Self.allowed(final), data.count <= limit else { throw BBCError.message("Channel 4 returned an invalid response.") }
            if r.statusCode == 401 || r.statusCode == 403 { throw BBCError.message("Channel 4 declined this playback session. Account or regional access may be required.") }
            if r.statusCode == 404, let unavailableMessage { throw BBCError.message(unavailableMessage) }
            guard r.statusCode == 200 else { throw BBCError.message("Channel 4 request failed (HTTP \(r.statusCode)). Please retry.") }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let e as BBCError { throw e }
        catch { throw BBCError.message("Could not reach Channel 4 (network code \((error as NSError).code)). Please retry.") }
    }
}

actor Channel4PlaybackAPI {
    static let shared = Channel4PlaybackAPI()
    private var envelopes: [Bool: (Date, Data, Data)] = [:]
    /// Channel 4's first-party clients wrap the licence-service address in an
    /// AES envelope. This decodes service metadata, never a media/content key.
    private func licenceAddress(_ token: String, live: Bool) async throws -> URL {
        let materials: (Data, Data)
        if let cached = envelopes[live], Date().timeIntervalSince(cached.0) < 900 { materials = (cached.1, cached.2) }
        else {
            let raw = live ? "https://static.channel4.com/all4-live-player/latest/bundle.app.js" : "https://static.c4assets.com/all4-player/latest/bundle.app.js"
            let script = String(decoding: try await Channel4HTTP.shared.data(URL(string: raw)!), as: UTF8.self)
            let pattern = live ? #"ais:\{url:"[^"]*",key:"([^\"]+)",iv:"([^\"]+)""# : #""bytes1":"([^\"]+)","bytes2":"([^\"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                  let a = Range(match.range(at: 1), in: script), let b = Range(match.range(at: 2), in: script) else { throw BBCError.message("Channel 4's playback configuration changed. Please update Telly.") }
            let key = Data(script[a].utf8), iv = Data(script[b].utf8)
            guard [16,24,32].contains(key.count), iv.count == 16 else { throw BBCError.message("Channel 4 returned an invalid playback configuration.") }
            materials = (key, iv); envelopes[live] = (Date(), key, iv)
        }
        guard let encrypted = Data(base64Encoded: token), !encrypted.isEmpty, encrypted.count < 16384 else { throw BBCError.message("Channel 4 returned an incomplete playback session.") }
        var output = Data(count: encrypted.count + kCCBlockSizeAES128); var written = 0
        let status = output.withUnsafeMutableBytes { dst in encrypted.withUnsafeBytes { input in materials.0.withUnsafeBytes { key in materials.1.withUnsafeBytes { iv in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, materials.0.count, iv.baseAddress, input.baseAddress, encrypted.count, dst.baseAddress, encrypted.count + kCCBlockSizeAES128, &written)
        } } } }
        guard status == kCCSuccess else { throw BBCError.message("Channel 4's playback session could not be read. Please retry.") }
        output.count = written
        let raw = String(decoding: output, as: UTF8.self).replacingOccurrences(of: "http://", with: "https://")
        guard let url = URL(string: raw), url.host == "keys.c4.aws.redbeemedia.com", url.path == "/v1/fps", url.scheme == "https", url.user == nil, url.password == nil else { throw BBCError.message("Channel 4 returned an unsupported FairPlay service.") }
        return url
    }
    func source(id: String, live: Bool) async throws -> PlaybackSource {
        guard id.range(of: live ? #"^(C4|E4|M4|F4|4S)$"# : #"^[0-9]+-[0-9]+$"#, options: .regularExpression) != nil else { throw BBCError.message("Invalid Channel 4 programme.") }
        let path = live ? "/simulcast/channels/\(id)" : "/vod/stream/\(id)"
        let data = try await Channel4HTTP.shared.data(URL(string: "https://www.channel4.com" + path)!, unavailableMessage: live ? "This Channel 4 live channel is currently unavailable." : "This episode is not currently available on Channel 4. It may not have aired yet or may have expired. Reopen the programme to refresh its available episodes.")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BBCError.message("Channel 4 returned no playback details.") }
        if live, let slot = root["slotInfo"] as? [String: Any], slot["simulcastRights"] as? Bool == false { throw BBCError.message("This programme is unavailable on Channel 4's live stream.") }
        let video = live ? root["channelInfo"] as? [String: Any] ?? [:] : root
        let profiles = video["videoProfiles"] as? [[String: Any]] ?? []
        let names = live ? ["fps-livestream-yospace-1", "fps-livestream-1"] : ["hls-dyn-stream-1", "fps-stream-1"]
        guard let profile = names.compactMap({ name in profiles.first { $0["name"] as? String == name } }).first else { throw BBCError.message("Channel 4 did not offer an HLS/FairPlay profile.") }
        guard let stream = (profile["streams"] as? [[String: Any]])?.first, let raw = stream["uri"] as? String,
              let manifest = URL(string: raw.replacingOccurrences(of:"http://",with:"https://")) else { throw BBCError.message("Channel 4 returned an incomplete stream address.") }
        guard Channel4HTTP.allowed(manifest) else { throw BBCError.message("Channel 4 returned an unsupported media host (\(manifest.host ?? "unknown")).") }
        guard let token = stream["token"] as? String, !token.isEmpty else { throw BBCError.message("Channel 4 returned an incomplete FairPlay session.") }
        let licence = try await licenceAddress(token, live: live)
        let certificate = try await Channel4HTTP.shared.data(URL(string: "https://static.c4assets.com/all4-dashjs/1.0.23/channel4-fps-cert.der")!, limit: 65536)
        var source = PlaybackSource(url: manifest, requested1080: false)
        source.fairPlayCertificate = certificate
        source.channel4FairPlay = Channel4FairPlayConfig(licence: licence, manifest: manifest, live: live)
        if !live {
            let captions = root["subtitlesAssets"] as? [[String: Any]] ?? []
            source.channel4Subtitles = captions.compactMap { row -> URL? in
                guard let raw = row["url"] as? String, let url = URL(string:raw), url.scheme == "https", url.host == "subs.channel4.com", url.path.hasSuffix(".m3u8") else { return nil }
                return url
            }.first
        }
        return source
    }
}

final class Channel4FairPlaySession: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let config: Channel4FairPlayConfig
    private let certificate: Data
    private let report: @Sendable (String, Bool) -> Void
    private let lock = NSLock()
    private var active = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    init(config: Channel4FairPlayConfig, certificate: Data, report: @escaping @Sendable (String, Bool) -> Void) {
        self.config = config; self.certificate = certificate; self.report = report
        super.init(); session.setDelegate(self, queue: DispatchQueue(label: "org.tellyplayer.channel4.fairplay"))
    }
    func attach(to asset: AVURLAsset) { session.addContentKeyRecipient(asset) }
    func stop() {
        lock.lock(); active = false; let pending = Array(tasks.values); tasks.removeAll(); lock.unlock()
        pending.forEach { $0.cancel() }; session.expire()
    }
    func contentKeySession(_ session: AVContentKeySession, didProvide request: AVContentKeyRequest) { handle(request) }
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest request: AVContentKeyRequest) { handle(request) }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed request: AVContentKeyRequest) { report("Channel 4 FairPlay accepted the licence.", false) }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest: AVContentKeyRequest, didFailWithError error: Error) { report("Channel 4 FairPlay rejected the response (\((error as NSError).code)).", true) }
    private func finished(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    private func handle(_ request: AVContentKeyRequest) {
        lock.lock(); guard active else { lock.unlock(); return }
        let id = UUID()
        tasks[id] = Task { [self] in
            defer { finished(id) }
            do {
                let raw = (request.identifier as? URL)?.absoluteString ?? request.identifier as? String ?? ""
                guard let keyURL = URL(string: raw), keyURL.scheme == "skd", let contentID = keyURL.host, !contentID.isEmpty else { throw BBCError.message("Channel 4 provided an invalid content identifier.") }
                report("Requesting a Channel 4 licence for this Apple TV…", false)
                let spc: Data = try await withCheckedThrowingContinuation { continuation in
                    request.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: Data(contentID.utf8), options: [AVContentKeyRequestProtocolVersionsKey: [1]]) { data, error in
                        if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? BBCError.message("Could not create the Channel 4 FairPlay request.")) }
                    }
                }
                try Task.checkCancellation()
                let body = try JSONSerialization.data(withJSONObject: ["video": ["url": config.manifest.absoluteString, "type": config.live ? "simulcast" : "ondemand"], "acSerial": 1, "spc": spc.base64EncodedString()])
                let response = try await Channel4HTTP.shared.data(config.licence, body: body, limit: 1_000_000)
                guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any], let value = root["ckc"] as? String, let ckc = Data(base64Encoded: value), !ckc.isEmpty else { throw BBCError.message("Channel 4 did not supply a FairPlay licence. Please retry.") }
                try Task.checkCancellation()
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
            } catch is CancellationError { }
            catch {
                let message = (error as? BBCError)?.localizedDescription ?? "Channel 4 FairPlay request failed (\((error as NSError).code))."
                report(message, true); request.processContentKeyResponseError(BBCError.message(message))
            }
        }; lock.unlock()
    }
}

/// Adds the broadcaster's segmented WebVTT rendition without touching encrypted media.
enum Channel4Subtitles {
    static func master(_ text: String, base: URL, subtitles: URL) throws -> Data {
        guard text.hasPrefix("#EXTM3U"), text.contains("#EXT-X-STREAM-INF:"), subtitles.host == "subs.channel4.com", subtitles.scheme == "https" else { throw BBCError.message("Channel 4 subtitles are unavailable.") }
        let uri = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        var lines = ["#EXTM3U", "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"channel4-subtitles\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI=\"\(subtitles.absoluteString)\""]
        for raw in text.components(separatedBy: .newlines) where !raw.isEmpty && raw != "#EXTM3U" {
            var line = raw
            for match in uri.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                if let range = Range(match.range(at:1), in:line), let url = URL(string:String(line[range]),relativeTo:base)?.absoluteURL { line.replaceSubrange(range,with:url.absoluteString) }
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") { line += ",SUBTITLES=\"channel4-subtitles\"" }
            else if !line.hasPrefix("#"), let url = URL(string:line,relativeTo:base)?.absoluteURL { line = url.absoluteString }
            lines.append(line)
        }
        return Data((lines.joined(separator:"\n")+"\n").utf8)
    }
}
