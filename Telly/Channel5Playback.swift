// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation

actor Channel5PlaybackAPI {
    static let shared = Channel5PlaybackAPI()
    private var settings: (Date,[String:Any])?
    private var certificate: (Date,Data)?
    private func config() async throws -> [String:Any] {
        if let settings, Date().timeIntervalSince(settings.0) < 900 { return settings.1 }
        let data = try await Channel5HTTP.shared.data(URL(string:"https://cassie.channel5.com/platform/my5desktopng/config.json")!)
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], let player = root["c5playerSettings"] as? [String:Any] else { throw Channel5Error.message("Channel 5's player configuration is unavailable.") }
        settings = (Date(),player); return player
    }
    static func fairPlay(_ metadata: [String:Any]) throws -> (URL,URL) {
        guard let assets = metadata["assets"] as? [[String:Any]], let asset = assets.first(where: { ($0["drm"] as? String)?.lowercased() == "fairplay" }),
              let rawLicence = asset["keyserver"] as? String, let licence = URL(string:rawLicence), Channel5Wire.licenceAllowed(licence),
              let rendition = (asset["renditions"] as? [[String:Any]])?.sorted(by:{ ($0["renditionid"] as? Int ?? 0) < ($1["renditionid"] as? Int ?? 0) }).first,
              let raw = rendition["url"] as? String, let manifest = URL(string:raw), Channel5HTTP.mediaAllowed(manifest), manifest.path.hasSuffix(".m3u8") else { throw Channel5Error.message("Channel 5 did not offer a supported Apple TV stream for this programme.") }
        return (manifest,licence)
    }
    func licence(for config: Channel5FairPlayConfig) async throws -> URL {
        if Date().timeIntervalSince(config.created) < 60 { return config.licence }
        let token = try await Channel5AccountService.shared.token()
        return try Self.fairPlay(await Channel5Wire.metadata(id:config.programmeID,live:config.live,session:token)).1
    }
    static func liveURL(_ original: URL, id: String, settings: [String:Any]) throws -> URL {
        guard original.host == "dai.google.com", let ads = settings["googleDaiAdSettings"] as? [String:Any], var template = ads["queryString"] as? String else { return original }
        template = template.replacingOccurrences(of:"{c5id_lowercase}",with:id.lowercased()).replacingOccurrences(of:"{vcid}",with:UUID().uuidString).replacingOccurrences(of:"{tfcd}",with:id == "C5CH11" ? "1" : "0")
        let query = template.hasPrefix("?") ? String(template.dropFirst()) : template
        // No consent string is invented; mirror the public client's omission
        // when the user has not supplied one, preserving the DAI session route.
        let parts = query.split(separator:"&").filter { !$0.contains("{consent}") && !$0.contains("{") }.joined(separator:"&")
        var url = URLComponents(url:original,resolvingAgainstBaseURL:false)!
        let base = url.percentEncodedQuery
        url.percentEncodedQuery = [base,parts.isEmpty ? nil : parts].compactMap { $0 }.joined(separator:"&")
        guard let result = url.url, Channel5HTTP.mediaAllowed(result) else { throw Channel5Error.message("Invalid Channel 5 live session.") }
        return result
    }
    func source(id: String, live: Bool) async throws -> PlaybackSource {
        let token = try await Channel5AccountService.shared.token()
        let metadata: [String:Any]
        do { metadata = try await Channel5Wire.metadata(id:id,live:live,session:token) }
        catch Channel5Error.signInRequired { try? await Channel5AccountService.shared.signOut(); throw Channel5Error.signInRequired }
        let (manifest,licence) = try Self.fairPlay(metadata)
        let config = try await config()
        let cert: Data
        if let certificate, Date().timeIntervalSince(certificate.0) < 900 { cert = certificate.1 }
        else {
            guard let raw = config["fairplayApplicationCertificateUrl"] as? String, let url = URL(string:raw), url.host == "c5apps.channel5.com", Channel5HTTP.allowed(url) else { throw Channel5Error.message("Channel 5's FairPlay certificate is unavailable.") }
            cert = try await Channel5HTTP.shared.data(url)
            guard cert.count > 500, cert.count < 16384, cert.first == 0x30 else { throw Channel5Error.message("Channel 5 returned an invalid FairPlay certificate.") }
            certificate = (Date(),cert)
        }
        var source = PlaybackSource(url:live ? try Self.liveURL(manifest,id:id,settings:config) : manifest,requested1080:false)
        source.fairPlayCertificate = cert
        source.channel5FairPlay = Channel5FairPlayConfig(licence:licence,programmeID:id,live:live,created:Date())
        return source
    }
}

final class Channel5FairPlaySession: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let session = AVContentKeySession(keySystem:.fairPlayStreaming)
    private let config: Channel5FairPlayConfig
    private let certificate: Data
    private let report: @Sendable (String,Bool) -> Void
    private let lock = NSLock()
    private var active = true
    private var tasks: [UUID:Task<Void,Never>] = [:]
    init(config: Channel5FairPlayConfig, certificate: Data, report: @escaping @Sendable (String,Bool)->Void) {
        self.config=config; self.certificate=certificate; self.report=report
        super.init(); session.setDelegate(self,queue:DispatchQueue(label:"org.tellyplayer.channel5.fairplay"))
    }
    func attach(to asset: AVURLAsset) { session.addContentKeyRecipient(asset) }
    func stop() { lock.lock(); active=false; let pending=Array(tasks.values);tasks.removeAll();lock.unlock();pending.forEach { $0.cancel() };session.expire() }
    func contentKeySession(_ session: AVContentKeySession, didProvide request: AVContentKeyRequest) { handle(request) }
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest request: AVContentKeyRequest) { handle(request) }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequestDidSucceed request: AVContentKeyRequest) { report("Channel 5 FairPlay accepted the licence.",false) }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest: AVContentKeyRequest, didFailWithError error: Error) { report("Channel 5 FairPlay rejected the response (\((error as NSError).code)).",true) }
    private func finished(_ id: UUID) { lock.lock();tasks[id]=nil;lock.unlock() }
    private func handle(_ request: AVContentKeyRequest) {
        lock.lock();guard active else { lock.unlock();return }
        let id=UUID()
        tasks[id]=Task { [self] in
            defer { finished(id) }
            do {
                let raw=(request.identifier as? URL)?.absoluteString ?? request.identifier as? String ?? ""
                let contentID=try Channel5Wire.fairPlayContentID(raw)
                report("Requesting a Channel 5 licence for this Apple TV…",false)
                let spc: Data = try await withCheckedThrowingContinuation { continuation in
                    request.makeStreamingContentKeyRequestData(forApp:certificate,contentIdentifier:Data(contentID.utf8),options:[AVContentKeyRequestProtocolVersionsKey:[1]]) { data,error in
                        if let data { continuation.resume(returning:data) } else { continuation.resume(throwing:error ?? Channel5Error.message("Could not create Channel 5's FairPlay challenge.")) }
                    }
                }
                try Task.checkCancellation()
                let licence=try await Channel5PlaybackAPI.shared.licence(for:config)
                // Match the provider's FairPlay form transport, preserving case.
                let body=Data(("spc="+Channel5Wire.formValue(spc.base64EncodedString())+"&"+contentID).utf8)
                let response=try await Channel5HTTP.shared.send(licence,method:"POST",body:body,contentType:"application/x-www-form-urlencoded",limit:2_000_000)
                guard response.status == 200, !response.data.isEmpty else { throw Channel5Error.message("Channel 5 declined the FairPlay request (HTTP \(response.status)). Please retry.") }
                let ckc: Data
                if let text=String(data:response.data,encoding:.utf8), let decoded=Data(base64Encoded:text.trimmingCharacters(in:.whitespacesAndNewlines)), !decoded.isEmpty { ckc=decoded }
                else { ckc=response.data }
                try Task.checkCancellation()
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData:ckc))
            } catch is CancellationError { }
            catch {
                let message = (error as? Channel5Error)?.localizedDescription ?? "Channel 5 FairPlay request failed (\((error as NSError).code))."
                report(message,true);request.processContentKeyResponseError(Channel5Error.message(message))
            }
        };lock.unlock()
    }
}
