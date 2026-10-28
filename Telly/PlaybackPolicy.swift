// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum PlaybackPolicy {
    /// A missing/unavailable UHD rendition must not prevent watching in HD.
    /// Cancellation is never a reason to start another network request.
    static func bestSource(uhd: (() async throws -> PlaybackSource)?, hd: () async throws -> PlaybackSource) async throws -> PlaybackSource {
        try Task.checkCancellation()
        if let uhd {
            do { return try await uhd() }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        return try await hd()
    }
    static func badge(height: Int, videoRange: String?) -> String? {
        guard height > 0 else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 1080 { return "FHD" }
        if height >= 720 { return "HD" }
        return "SD"
    }
}
