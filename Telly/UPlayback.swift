// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation

actor UPlaybackAPI {
    static let shared = UPlaybackAPI()
    private var policy: (Date,String)?
    private var certificates: [URL:(Date,Data)] = [:]
    private func metadata(_ id: String) async throws -> (URL,URL,UFairPlayConfig) {
        let key: String
        if let policy, Date().timeIntervalSince(policy.0) < 900 { key = policy.1 }
        else {
            let config = try await UHTTP.shared.send(UPlaybackWire.playerConfigURL)
            guard config.status == 200 else { throw UError.message("U’s player configuration is unavailable (HTTP \(config.status)).") }
            key = try UPlaybackWire.policy(config.data); policy = (Date(),key)
        }
        let response = try await UHTTP.shared.send(UPlaybackWire.videoURL(id),policy:key)
        guard response.status == 200 else { throw UError.message("This U episode could not be opened (HTTP \(response.status)). It may have expired or be unavailable in your location.") }
        return try UPlaybackWire.fairPlay(response.data,id:id)
    }
    func source(id: String) async throws -> PlaybackSource {
        _ = try await UAccountService.shared.session()
        let (manifest,certificateURL,config) = try await metadata(id)
        let certificate: Data
        if let cached = certificates[certificateURL], Date().timeIntervalSince(cached.0) < 900 { certificate = cached.1 }
        else {
            let response = try await UHTTP.shared.send(certificateURL,limit:16384)
            guard response.status == 200, response.data.count > 500, response.data.first == 0x30 else { throw UError.message("U returned an invalid FairPlay certificate.") }
            certificate = response.data; certificates[certificateURL] = (Date(),certificate)
        }
        var result = PlaybackSource(url:manifest,requested1080:false)
        result.fairPlayCertificate = certificate; result.uFairPlay = config
        return result
    }
    func licence(_ config: UFairPlayConfig) async throws -> URL {
        _ = try await UAccountService.shared.session()
        if Date().timeIntervalSince(config.created) < 60 { return config.licence }
        return try await metadata(config.videoID).2.licence
    }
}

final class UFairPlaySession: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let session = AVContentKeySession(keySystem:.fairPlayStreaming)
    private let config: UFairPlayConfig
    private let certificate: Data
    private let report: @Sendable (String,Bool) -> Void
    private let lock = NSLock()
    private var tasks: [UUID:Task<Void,Never>] = [:]
    private var stopped = false
    init(config: UFairPlayConfig, certificate: Data, report: @escaping @Sendable (String,Bool) -> Void) {
        self.config = config; self.certificate = certificate; self.report = report
        super.init(); session.setDelegate(self,queue:DispatchQueue(label:"org.tellyplayer.u.fairplay"))
    }
    func attach(to asset: AVURLAsset) { session.addContentKeyRecipient(asset) }
    func stop() {
        lock.lock(); stopped = true; let pending = Array(tasks.values); tasks.removeAll(); lock.unlock()
        pending.forEach { $0.cancel() }; session.expire()
    }
    private func finished(_ id: UUID) { lock.lock(); tasks[id] = nil; lock.unlock() }
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) { process(keyRequest) }
    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) { process(keyRequest) }
    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        report("U FairPlay rejected the playback response (\((err as NSError).code)). Close and retry.",true)
    }
    private func process(_ request: AVContentKeyRequest) {
        lock.lock(); guard !stopped else { lock.unlock(); return }; let id = UUID()
        tasks[id] = Task { [self] in
            defer { finished(id) }
            do {
                let raw = (request.identifier as? URL)?.absoluteString ?? request.identifier as? String ?? ""
                let contentID = try UPlaybackWire.contentID(raw)
                report("Requesting U’s protected playback licence…",false)
                let spc: Data = try await withCheckedThrowingContinuation { continuation in
                    request.makeStreamingContentKeyRequestData(forApp:certificate,contentIdentifier:Data(contentID.utf8),options:[AVContentKeyRequestProtocolVersionsKey:[1]]) { data,error in
                        if let data { continuation.resume(returning:data) }
                        else { continuation.resume(throwing:error ?? UError.message("Could not create U’s FairPlay challenge.")) }
                    }
                }
                try Task.checkCancellation()
                let url = try await UPlaybackAPI.shared.licence(config)
                let body = try UPlaybackWire.licenceBody(spc:spc,contentID:contentID)
                let response = try await UHTTP.shared.send(url,method:"POST",body:body,limit:2_000_000)
                guard response.status == 200, response.data.count >= 16 else { throw UError.message("U declined the FairPlay request (HTTP \(response.status)). Close and retry.") }
                try Task.checkCancellation()
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData:response.data))
            } catch is CancellationError { }
            catch {
                let error = (error as? UError) ?? .message("U’s protected playback request failed (\((error as NSError).code)).")
                report(error.localizedDescription,true); request.processContentKeyResponseError(error)
            }
        }; lock.unlock()
    }
}
