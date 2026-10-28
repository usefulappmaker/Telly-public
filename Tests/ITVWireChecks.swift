let id = "skd://itvpnp.live.ott.irdeto.com/Streaming/getckc?CrmId=itvpnp&ContentId=episode&KeyId=abc"
let endpoint = try ITVFairPlayWire.licenceURL(id); assert(endpoint.scheme == "https")
let cid = try ITVFairPlayWire.contentID(id)
assert(String(decoding: cid, as: UTF8.self) == "CrmId=itvpnp&ContentId=episode&KeyId=abc")
let liveID = "skd://itvpnp.live.ott.irdeto.com/streaming/getckc?CrmId=itvpnp&AccountId=itv&ContentId=live&keyId=123%2B456"
let liveEndpoint = try ITVFairPlayWire.licenceURL(liveID)
assert(liveEndpoint.path == "/streaming/getckc")
let liveContentID = try ITVFairPlayWire.contentID(liveID)
assert(String(decoding: liveContentID, as: UTF8.self).hasSuffix("keyId=123%2B456"))
let themedID = "skd://fairplay-license.itvx.vudrm.tech/v2/license/F03"
let themedEndpoint = try ITVFairPlayWire.licenceURL(themedID)
let themedContent = try ITVFairPlayWire.contentID(themedID)
assert(themedEndpoint.absoluteString == "https://fairplay-license.itvx.vudrm.tech/v2/license/F03")
assert(String(decoding: themedContent, as: UTF8.self) == "F03")
let themedBody = ITVFairPlayWire.licenceBody(challenge: Data([1,2,3]), contentID: themedContent)
assert(String(decoding: themedBody, as: UTF8.self) == "spc=AQID&assetId=F03")
let spc = Data([0, 1, 255, 128, 63, 43])
let themedRequest = try ITVFairPlayWire.licenceRequest(identifier: themedID, challenge: spc)
assert(themedRequest.httpBody == spc)
assert(themedRequest.httpMethod == "POST")
assert(themedRequest.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
let mainRequest = try ITVFairPlayWire.licenceRequest(identifier: liveID, challenge: spc)
assert(mainRequest.httpBody != spc)
assert(mainRequest.httpBody == ITVFairPlayWire.licenceBody(challenge: spc, contentID: liveContentID))
let asciiBinary = Data("AQID".utf8)
let themedBinary = try ITVFairPlayWire.responseData(asciiBinary, mime: "application/octet-stream", endpoint: themedEndpoint)
assert(themedBinary == asciiBinary) // Binary CKC must not be guessed to be base64.
let ownFailure = ITVProbeError(stage: "FairPlay licence", detail: "HTTP 400") as NSError
assert(ITVFairPlayWire.failureMessage(ownFailure) == "FairPlay licence: HTTP 400")
let systemFailure = NSError(domain: "AVFoundationErrorDomain", code: -11800)
assert(ITVFairPlayWire.failureMessage(systemFailure).contains("AVFoundationErrorDomain -11800"))
let bridged = ITVProbeError(stage: "FairPlay", detail: "Example failure") as NSError
assert(bridged.localizedDescription == "FairPlay: Example failure")
for bad in ["skd://fairplay-license.itvx.vudrm.tech.evil.example/v2/license/F03", "skd://fairplay-license.itvx.vudrm.tech/v2/license/../../other", "skd://fairplay-license.itvx.vudrm.tech/v2/license/OTHER", "skd://user@fairplay-license.itvx.vudrm.tech/v2/license/F03"] {
 do { _ = try ITVFairPlayWire.licenceURL(bad); fatalError("Accepted unexpected themed licence endpoint") } catch {}
}
for bad in ["https://itvpnp.live.ott.irdeto.com/Streaming/getckc", "skd://evil.example/Streaming/getckc?x=y", "skd://itvpnp.live.ott.irdeto.com.evil.example/Streaming/getckc?x=y", "skd://user@itvpnp.live.ott.irdeto.com/Streaming/getckc?x=y"] {
 do { _ = try ITVFairPlayWire.licenceURL(bad); fatalError("Accepted unsafe endpoint") } catch {}
}
let body = String(decoding: ITVFairPlayWire.licenceBody(challenge: Data([251,255]), contentID: cid), as: UTF8.self)
assert(body.contains("spc=%2B%2F8%3D"))
assert(body.contains("assetId=CrmId%3Ditvpnp%26ContentId%3Depisode%26KeyId%3Dabc"))
let decoded = try ITVFairPlayWire.decodeLicence(Data("<ckc>AQID</ckc>".utf8), mime: "text/plain")
assert(decoded == Data([1,2,3]))
let binary = try ITVFairPlayWire.decodeLicence(Data([0,255,128,5]), mime: "application/octet-stream"); assert(binary == Data([0,255,128,5]))
for data in [Data(), Data("{\"error\":\"denied\"}".utf8), Data("<html>error</html>".utf8)] {
 do { _ = try ITVFairPlayWire.decodeLicence(data, mime: "text/plain"); fatalError("Accepted invalid licence") } catch {}
}
print("FairPlay wire fixtures passed: endpoint restrictions, content ID, form encoding, licence decoding and invalid responses.")
