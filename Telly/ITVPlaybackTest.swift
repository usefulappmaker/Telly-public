// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVKit

/// Native FairPlay feasibility probe. No browser session, copied licence or raw key storage.
struct ITVTestLandingView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 30) {
                Text("Telly").font(.system(size: 66, weight: .bold))
                Text("ITV playback compatibility").font(.title)
                Text("Test native Apple TV playback of The Way Home, Series 1, Episode 1.")
                    .font(.title3).foregroundStyle(.secondary)
                NavigationLink("Test ITV playback") { ITVPlaybackTestView() }
                NavigationLink("Open BBC library") { HomeView() }
                Text("Experimental build · ITV browsing, account sign-in and advert scheduling are not included.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(80).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct ITVPlaybackTestView: View {
    @StateObject private var model = ITVPlaybackProbe()
    @State private var showingPlayer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("ITV · The Way Home").font(.largeTitle).bold()
            Text("Series 1 · Episode 1").font(.title2)
            Text(model.status).font(.title3)
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack(spacing: 28) {
                Button(model.busy ? "Preparing…" : "Play episode") {
                    model.start { showingPlayer = true }
                }.disabled(model.busy)
                if model.busy { Button("Cancel") { model.stop() } }
                if model.hasItem { Button("Show player") { showingPlayer = true } }
            }
            Text("Diagnostics").font(.headline).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(size: 22, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 360)
            #if targetEnvironment(simulator)
            Text("Simulator: interface and network checks only. Test protected video on a physical Apple TV.")
                .font(.callout).foregroundStyle(.secondary)
            #endif
        }.padding(65)
            .fullScreenCover(isPresented: $showingPlayer, onDismiss: { model.pause() }) {
                ITVNativePlayer(player: model.player)
                    .overlay(alignment: .topLeading) {
                        if let error = model.error {
                            Text(error).font(.callout).padding(25).background(.black.opacity(0.85)).padding(45)
                        }
                    }
            }
            .onDisappear { if !showingPlayer { model.stop() } }
    }
}

private struct ITVNativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player; return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

struct ITVProbeError: LocalizedError, CustomNSError {
    let stage: String
    let detail: String
    var errorDescription: String? { "\(stage): \(detail)" }
    static var errorDomain: String { "Telly.ITVPlayback" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "ITV playback failed."] }
}

/// Public URLs and non-secret wire-format helpers, kept separate for fixture checks.
enum ITVFairPlayWire {
    static let certificateURL = URL(string: "https://fairplay-drm.cloudfront.prd.ottstream.itv.com/cert-FairPlay-itv.der")!
    static let playlistURL = URL(string: "https://magni.itv.com/playlist/itvonline/ITV/10_8290_0001.001")!
    static func licenceURL(_ identifier: String) throws -> URL {
        guard var parts = URLComponents(string: identifier), parts.scheme == "skd",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else {
            throw ITVProbeError(stage: "FairPlay", detail: "Unexpected content-key endpoint.")
        }
        let irdeto = parts.host == "itvpnp.live.ott.irdeto.com" && ["/Streaming/getckc", "/streaming/getckc"].contains(parts.path)
        let themed = parts.host == "fairplay-license.itvx.vudrm.tech" && parts.path.range(of: "^/v2/license/F[0-9]{2,3}$", options: .regularExpression) != nil
        guard irdeto || themed else { throw ITVProbeError(stage: "FairPlay", detail: "Unsupported ITV licence service.") }
        parts.scheme = "https"
        guard let url = parts.url else { throw ITVProbeError(stage: "FairPlay", detail: "Invalid licence URL.") }
        return url
    }
    // ITV's web player uses the default FairPlay content ID: the SKD query string.
    static func contentID(_ identifier: String) throws -> Data {
        _ = try licenceURL(identifier)
        let parts = URLComponents(string: identifier)!
        if parts.host == "fairplay-license.itvx.vudrm.tech" {
            return Data((parts.path.split(separator: "/").last.map(String.init) ?? "").utf8)
        }
        guard let query = parts.percentEncodedQuery, !query.isEmpty else {
            throw ITVProbeError(stage: "FairPlay", detail: "The content identifier is missing.")
        }
        return Data(query.utf8)
    }
    static func licenceBody(challenge: Data, contentID: Data) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return Data(("spc=" + escape(challenge.base64EncodedString()) + "&assetId=" + escape(String(decoding: contentID, as: UTF8.self))).utf8)
    }
    static func isThemed(_ endpoint: URL) -> Bool { endpoint.host == "fairplay-license.itvx.vudrm.tech" }
    static func licenceRequest(identifier: String, challenge: Data) throws -> URLRequest {
        let endpoint = try licenceURL(identifier)
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        // ITV's registered THEO FairPlay integration forwards the raw SPC with
        // this header. Main-channel Irdeto also accepts the existing form format.
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.itv.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.itv.com/", forHTTPHeaderField: "Referer")
        request.httpBody = isThemed(endpoint) ? challenge : licenceBody(challenge: challenge, contentID: try contentID(identifier))
        return request
    }
    static func responseData(_ data: Data, mime: String?, endpoint: URL) throws -> Data {
        if isThemed(endpoint) {
            guard !data.isEmpty, data.count <= 1024 * 1024,
                  mime?.contains("json") != true, mime?.contains("text") != true else {
                throw ITVProbeError(stage: "Themed-channel licence", detail: "ITV returned an invalid binary licence response.")
            }
            return data
        }
        return try decodeLicence(data, mime: mime)
    }
    static func failureMessage(_ error: NSError) -> String {
        if error.domain == ITVProbeError.errorDomain {
            return (error.userInfo[NSLocalizedDescriptionKey] as? String) ?? "The ITV licence request failed before a content-key response was supplied."
        }
        return "FairPlay rejected the content-key response (\(error.domain) \(error.code))."
    }
    static func decodeLicence(_ data: Data, mime: String?) throws -> Data {
        guard !data.isEmpty, data.count <= 1024 * 1024 else {
            throw ITVProbeError(stage: "Licence response", detail: "Empty or oversized response.")
        }
        if let text = String(data: data, encoding: .utf8) {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<ckc>"), value.hasSuffix("</ckc>") { value = String(value.dropFirst(5).dropLast(6)) }
            if let decoded = Data(base64Encoded: value), !decoded.isEmpty { return decoded }
            if mime?.contains("text") == true || mime?.contains("json") == true || value.hasPrefix("<") {
                throw ITVProbeError(stage: "Licence response", detail: "Server returned text instead of a FairPlay licence.")
            }
        }
        return data
    }
}

final class ITVProbeHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func fetch(_ request: URLRequest, stage: String, limit: Int = 2 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ITVProbeError(stage: stage, detail: "Missing HTTP response.") }
        guard http.statusCode == 200 else { throw ITVProbeError(stage: stage, detail: "HTTP \(http.statusCode). Playback may require an authorised ITV client or account.") }
        guard !data.isEmpty, data.count <= limit else { throw ITVProbeError(stage: stage, detail: "Empty or oversized response.") }
        return (data, http)
    }
    func cancel() { session.invalidateAndCancel() }
}

final class ITVFairPlaySession: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let queue = DispatchQueue(label: "org.tellyplayer.itv.fairplay")
    private let certificate: Data
    private let http: ITVProbeHTTP
    private let report: @Sendable (String, Bool) -> Void
    private let lock = NSLock()
    private var tasks = [UUID: Task<Void, Never>]()
    private var active = true
    init(certificate: Data, http: ITVProbeHTTP, report: @escaping @Sendable (String, Bool) -> Void) {
        self.certificate = certificate; self.http = http; self.report = report
        super.init(); keySession.setDelegate(self, queue: queue)
    }
    func attach(to asset: AVURLAsset) { keySession.addContentKeyRecipient(asset) }
    func stop() {
        lock.lock(); active = false; let pending = Array(tasks.values); tasks.removeAll(); lock.unlock()
        pending.forEach { $0.cancel() }; keySession.expire()
    }
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) { handle(keyRequest) }
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        report("FairPlay renewal requested", false); handle(keyRequest)
    }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        report(ITVFairPlayWire.failureMessage(err as NSError), true)
    }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
        report("FairPlay accepted the content-key response", false)
    }
    private func removeTask(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; tasks.removeValue(forKey: id)
    }
    private func handle(_ request: AVContentKeyRequest) {
        let id = UUID()
        lock.lock()
        guard active else { lock.unlock(); return }
        let task = Task { [self] in
            defer { removeTask(id) }
            do {
                let identifier: String
                if let url = request.identifier as? URL { identifier = url.absoluteString }
                else if let text = request.identifier as? String { identifier = text }
                else { throw ITVProbeError(stage: "FairPlay", detail: "Missing key identifier.") }
                let endpoint = try ITVFairPlayWire.licenceURL(identifier)
                let contentID = try ITVFairPlayWire.contentID(identifier)
                report("Generating an Apple TV FairPlay challenge", false)
                let challenge: Data = try await withCheckedThrowingContinuation { continuation in
                    request.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: contentID,
                        options: [AVContentKeyRequestProtocolVersionsKey: [1]]) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? ITVProbeError(stage: "FairPlay", detail: "Challenge generation failed.")) }
                    }
                }
                try Task.checkCancellation()
                let req = try ITVFairPlayWire.licenceRequest(identifier: identifier, challenge: challenge)
                report("Requesting a licence for this Apple TV", false)
                let (data, response) = try await http.fetch(req, stage: "FairPlay licence", limit: 1024 * 1024)
                let ckc = try ITVFairPlayWire.responseData(data, mime: response.mimeType, endpoint: endpoint)
                try Task.checkCancellation()
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
                report("Licence response submitted to AVFoundation", false)
            } catch is CancellationError { }
            catch {
                // URLSession errors can contain signed URLs. Show only the stage/domain/code.
                let message: String
                if let e = error as? ITVProbeError { message = e.localizedDescription }
                else { let e = error as NSError; message = "FairPlay request failed (\(e.domain) \(e.code))." }
                report(message, true)
                request.processContentKeyResponseError(ITVProbeError(stage: "ITV request", detail: message))
            }
        }
        tasks[id] = task; lock.unlock()
    }
}

@MainActor final class ITVPlaybackProbe: ObservableObject {
    @Published var status = "Ready to test native FairPlay playback."
    @Published var error: String?
    @Published var busy = false
    @Published var hasItem = false
    @Published var events = [String]()
    let player = AVPlayer()
    private var operation: Task<Void, Never>?
    private var fairplay: ITVFairPlaySession?
    private var http: ITVProbeHTTP?
    private var statusObservation: NSKeyValueObservation?
    private var timer: Any?
    private var generation = UUID()
    func log(_ text: String, failure: Bool = false) {
        events.append(text); if events.count > 25 { events.removeFirst() }
        status = text; if failure { error = text; busy = false; player.pause() }
    }
    func start(ready: @escaping () -> Void) {
        stop(); events = []; error = nil; busy = true
        let id = generation, client = ITVProbeHTTP(); http = client
        operation = Task { [self] in
            defer { if generation == id { busy = false } }
            do {
                log("Requesting a fresh ITV playback session")
                let features = ["hls", "fairplay", "outband-webvtt", "hd", "single-track"]
                var req = URLRequest(url: ITVFairPlayWire.playlistURL); req.httpMethod = "POST"
                req.setValue("application/vnd.itv.vod.playlist.v2+json", forHTTPHeaderField: "Accept")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["client": ["id": "browser"],
                    "variantAvailability": ["featureset": ["min": features, "max": features], "platformTag": "dotcom"]])
                let (body, _) = try await client.fetch(req, stage: "ITV playback session")
                guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let playlist = root["Playlist"] as? [String: Any], let video = playlist["Video"] as? [String: Any],
                      let files = video["MediaFiles"] as? [[String: Any]], let href = files.first?["Href"] as? String,
                      let base = URL(string: video["Base"] as? String ?? ""),
                      let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme == "https",
                      let host = url.host, host.hasSuffix(".content.itv.com") else {
                    throw ITVProbeError(stage: "Playback session", detail: "No supported HLS media URL was returned.")
                }
                log("ITV returned an HLS source")
                let (masterData, _) = try await client.fetch(URLRequest(url: url), stage: "HLS manifest")
                let master = String(decoding: masterData, as: UTF8.self)
                guard master.hasPrefix("#EXTM3U"), master.contains("com.apple.streamingkeydelivery") else {
                    throw ITVProbeError(stage: "HLS manifest", detail: "Expected FairPlay signalling was not found.")
                }
                log("Confirmed HLS with FairPlay protection")
                let (certificate, _) = try await client.fetch(URLRequest(url: ITVFairPlayWire.certificateURL), stage: "FairPlay certificate", limit: 128 * 1024)
                guard certificate.first == 0x30 else { throw ITVProbeError(stage: "FairPlay certificate", detail: "Unexpected certificate format.") }
                log("ITV application certificate received")
                try Task.checkCancellation(); guard generation == id else { return }
                #if targetEnvironment(simulator)
                log("Network checks passed. FairPlay playback requires the physical Apple TV.")
                return
                #else
                let fps = ITVFairPlaySession(certificate: certificate, http: client) { [weak self] text, failure in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        self.log(text, failure: failure)
                    }
                }
                fairplay = fps
                let asset = AVURLAsset(url: url); fps.attach(to: asset)
                let item = AVPlayerItem(asset: asset)
                item.externalMetadata = PlaybackModel.metadata(title: "The Way Home", subtitle: "Series 1 · Episode 1 · ITV TEST")
                statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    let state = item.status, code = (item.error as NSError?)?.code
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id else { return }
                        if state == .failed { self.log("Player failed (AVFoundation \(code ?? 0)). Check the licence diagnostics.", failure: true) }
                        if state == .readyToPlay { self.log("Player is ready") }
                    }
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                player.replaceCurrentItem(with: item); hasItem = true
                timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 2, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == id, time.seconds > 0,
                              let item = self.player.currentItem, item.presentationSize.height > 0 else { return }
                        let size = item.presentationSize
                        let text = "Playing · \(Int(size.width)) × \(Int(size.height)) · \(Int(time.seconds)) seconds"
                        self.status = text
                        if !self.events.contains(where: { $0.hasPrefix("Video decoded") }) { self.events.append("Video decoded on Apple TV · \(Int(size.width)) × \(Int(size.height))") }
                    }
                }
                log("Starting protected playback"); ready(); player.play()
                // A bounded startup deadline makes blocked licence requests visible to the tester.
                try await Task.sleep(nanoseconds: 40_000_000_000)
                guard generation == id, error == nil else { return }
                if player.currentTime().seconds < 1 || item.presentationSize.height == 0 {
                    log("Playback did not start within 40 seconds. Return to diagnostics and retry.", failure: true)
                }
                #endif
            } catch is CancellationError { }
            catch {
                guard generation == id else { return }
                if let e = error as? ITVProbeError { log(e.localizedDescription, failure: true) }
                else { let e = error as NSError; log("Preparation failed (\(e.domain) \(e.code)).", failure: true) }
            }
        }
    }
    func pause() { player.pause() }
    func stop() {
        generation = UUID(); operation?.cancel(); operation = nil
        if let timer { player.removeTimeObserver(timer) }; timer = nil
        statusObservation = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        fairplay?.stop(); fairplay = nil; http?.cancel(); http = nil
        busy = false; hasItem = false
    }
}

extension ITVCatalogueAPI {
    func playbackSource(for programme: Programme) async throws -> PlaybackSource {
        guard programme.premium != true else { throw ITVProbeError(stage: "ITV Premium", detail: "Account playback isn't available in this build.") }
        guard let endpoint = programme.itvPlaylistURL, endpoint.scheme == "https", endpoint.host == "magni.itv.com",
              endpoint.path.hasPrefix("/playlist/itvonline/") else { throw ITVProbeError(stage: "ITV", detail: "This episode has no valid playback address.") }
        let client = ITVProbeHTTP(); defer { client.cancel() }
        let features = ["hls", "fairplay", "outband-webvtt", "hd", "single-track"]
        var req = URLRequest(url: endpoint); req.httpMethod = "POST"; req.timeoutInterval = 25
        req.setValue("application/vnd.itv.vod.playlist.v2+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client": ["id": "browser"],
            "variantAvailability": ["featureset": ["min": features, "max": features], "platformTag": "ctv"]])
        let (body, _) = try await client.fetch(req, stage: "ITV playback session")
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let video = (root["Playlist"] as? [String: Any])?["Video"] as? [String: Any],
              let files = video["MediaFiles"] as? [[String: Any]], let href = files.first?["Href"] as? String,
              let base = URL(string: video["Base"] as? String ?? ""),
              let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme == "https",
              let host = url.host, host.hasSuffix(".content.itv.com") else { throw ITVProbeError(stage: "ITV playback", detail: "No compatible HLS source was returned.") }
        let (certificate, _) = try await client.fetch(URLRequest(url: ITVFairPlayWire.certificateURL), stage: "FairPlay certificate", limit: 128 * 1024)
        guard certificate.first == 0x30 else { throw ITVProbeError(stage: "FairPlay", detail: "Invalid application certificate.") }
        return PlaybackSource(url: url, requested1080: false, fairPlayCertificate: certificate)
    }
}

extension ITVLiveAPI {
    @MainActor func playbackSource(for channel: LiveChannel) async throws -> PlaybackSource {
        let url = try await ITVAccountService.shared.liveURL(channel: channel, osVersion: UIDevice.current.systemVersion, model: UIDevice.current.model)
        let client = ITVProbeHTTP(); defer { client.cancel() }
        let (certificate, _) = try await client.fetch(URLRequest(url: ITVFairPlayWire.certificateURL), stage: "FairPlay certificate", limit: 128 * 1024)
        guard certificate.first == 0x30 else { throw ITVProbeError(stage: "FairPlay", detail: "Invalid application certificate.") }
        return PlaybackSource(url: url, requested1080: false, fairPlayCertificate: certificate)
    }
}
