// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UIKit
import ImageIO
import CryptoKit

/// Bounded decoded-image cache. Disk access and image preparation stay off the
/// interface thread, and reused cards share one in-flight artwork request.
actor ProgrammeArtworkLoader {
    static let shared = ProgrammeArtworkLoader()
    private let cache = NSCache<NSURL,UIImage>()
    private var pending: [URL:Task<UIImage,Error>] = [:]
    init() { cache.countLimit=80;cache.totalCostLimit=48*1024*1024 }
    nonisolated static func cacheURL(_ url: URL) -> URL {
        let key=SHA256.hash(data:Data(url.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined()
        return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("programme-artwork",isDirectory:true).appendingPathComponent(key+".jpg")
    }
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard data.count<=8*1024*1024,let source=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { return nil }
        return UIImage(cgImage:image)
    }
    func image(_ url: URL) async throws -> UIImage {
        if let image=cache.object(forKey:url as NSURL) { return image }
        if let task=pending[url] { return try await task.value }
        let task=Task.detached(priority:.utility) {
            let file=Self.cacheURL(url)
            if let data=try? Data(contentsOf:file,options:.mappedIfSafe),let image=Self.decode(data) { return image }
            var request=URLRequest(url:url);request.timeoutInterval=12
            let (data,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200,let image=Self.decode(data) else { throw BBCError.message("Programme artwork is unavailable.") }
            try? FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? data.write(to:file,options:.atomic)
            return image
        }
        pending[url]=task
        defer { pending[url]=nil }
        let image=try await task.value
        let cost=image.cgImage.map { $0.bytesPerRow*$0.height } ?? 0
        cache.setObject(image,forKey:url as NSURL,cost:cost)
        return image
    }
}
