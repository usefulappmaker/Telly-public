// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Canonicalizes the single-track CMAF layout used by BBC UHD. Some fragments
/// have unreferenced bytes before their first sample; AVPlayer's HLS demuxer
/// rejects those even though the DASH trun points past them correctly.
enum FMP4Normalizer {
    private struct Box { let start: Int; let size: Int; let header: Int; let type: String; var end: Int { start + size } }
    static func normalize(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func uint(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, count <= 8, offset <= bytes.count - count else { throw BBCError.message("Truncated UHD media fragment.") }
            return bytes[offset..<offset+count].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func boxes(_ start: Int, _ end: Int) throws -> [Box] {
            var result = [Box](), offset = start
            while offset < end {
                guard end - offset >= 8 else { throw BBCError.message("Truncated UHD media box.") }
                let short = try uint(offset, 4), header = short == 1 ? 16 : 8
                let length = short == 1 ? try uint(offset + 8, 8) : (short == 0 ? UInt64(end - offset) : short)
                guard length >= header, length <= end - offset else { throw BBCError.message("Invalid UHD media box size.") }
                result.append(Box(start: offset, size: Int(length), header: header, type: String(decoding: bytes[offset+4..<offset+8], as: UTF8.self)))
                offset += Int(length)
            }
            return result
        }
        let top = try boxes(0, bytes.count)
        let moofs = top.filter { $0.type == "moof" }, mdats = top.filter { $0.type == "mdat" }
        guard moofs.count == 1, mdats.count == 1, let moof = moofs.first, let mdat = mdats.first, moof.end <= mdat.start else {
            throw BBCError.message("Unsupported UHD fragment layout.")
        }
        let trafs = try boxes(moof.start + moof.header, moof.end).filter { $0.type == "traf" }
        guard trafs.count == 1, let traf = trafs.first else { throw BBCError.message("Unsupported UHD fragment tracks.") }
        let children = try boxes(traf.start + traf.header, traf.end)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }), tfhd.size >= tfhd.header + 8,
              let trun = children.first(where: { $0.type == "trun" }), children.filter({ $0.type == "trun" }).count == 1, trun.size >= trun.header + 12 else {
            throw BBCError.message("Missing UHD fragment sample addressing.")
        }
        let tfhdFlags = try uint(tfhd.start + tfhd.header, 4) & 0xffffff
        let trunFlags = try uint(trun.start + trun.header, 4) & 0xffffff
        guard tfhdFlags & 0x020000 != 0, tfhdFlags & 1 == 0, trunFlags & 1 != 0 else {
            throw BBCError.message("Unsupported UHD fragment data offset.")
        }
        let offsetPosition = trun.start + trun.header + 8
        let rawOffset = try uint(offsetPosition, 4)
        let offset = Int(Int32(bitPattern: UInt32(rawOffset)))
        let payloadStart = mdat.start + mdat.header
        let padding = moof.start + offset - payloadStart
        guard padding >= 0, padding <= 4096, padding < mdat.size - mdat.header else { throw BBCError.message("Invalid UHD sample padding.") }
        guard padding > 0 else { return data }
        // Restrict rewriting to the BBC layout: one moof followed by its final
        // mdat. No subsequent indexes or absolute byte offsets need updating.
        guard mdat.end == bytes.count else { throw BBCError.message("Unsupported padded UHD fragment layout.") }
        var output = data
        func replaceUInt(_ position: Int, _ count: Int, _ value: UInt64) {
            let encoded = (0..<count).map { UInt8(truncatingIfNeeded: value >> ((count - 1 - $0) * 8)) }
            output.replaceSubrange(position..<position+count, with: encoded)
        }
        replaceUInt(offsetPosition, 4, UInt64(offset - padding))
        if mdat.header == 16 { replaceUInt(mdat.start + 8, 8, UInt64(mdat.size - padding)) }
        else if try uint(mdat.start, 4) != 0 { replaceUInt(mdat.start, 4, UInt64(mdat.size - padding)) }
        output.removeSubrange(payloadStart..<payloadStart+padding)
        return output
    }
}
