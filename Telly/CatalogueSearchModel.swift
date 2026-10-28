// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

struct SearchCatalogueSource {
    let revisions: [Int]
    let bbc: CatalogueIndexSnapshot
    let cached: [[CatalogueShow]]
}
struct SearchProviderBatch {
    let provider: ContentProvider
    var shows: [CatalogueShow] = []
    var failed = false
}
struct CatalogueSearchState {
    var query = ""
    var results: [CatalogueShow] = []
    var searching = false
    var error: String?
}

/// Text preparation, catalogue scans and ranking execute on this actor, never
/// in a SwiftUI body. An unchanged catalogue is prepared once for all queries.
actor ProgrammeSearchIndex {
    private struct Entry {
        var show: CatalogueShow
        let title: String
        let text: String
        init(_ show: CatalogueShow) {
            self.show = show
            title = ProgrammeSearchIndex.normalize(show.title)
            text = ProgrammeSearchIndex.normalize(show.title + " " + show.summary)
        }
        func rank(_ query: String) -> Int { title == query ? 0 : title.hasPrefix(query) ? 1 : title.contains(query) ? 2 : 3 }
    }
    private var revision: [Int]?
    private var entries: [Entry] = []
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
    }
    func prepare(_ source: SearchCatalogueSource) throws {
        guard revision != source.revisions else { return }
        let uhd = Dictionary(source.bbc.uhd.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        var next = [Entry](), seen = Set<String>()
        for list in [source.bbc.catalogue] + source.cached {
            for (position,original) in list.enumerated() {
                if position % 128 == 0 { try Task.checkCancellation() }
                guard seen.insert(original.id).inserted else { continue }
                var show = original
                if let known = uhd[show.id] { show.uhdListed = true;show.uhdEpisodeCount = known.uhdEpisodeCount }
                next.append(Entry(show))
            }
        }
        next.sort { $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending }
        try Task.checkCancellation()
        entries = next;revision = source.revisions
    }
    func matches(_ query: String) throws -> [CatalogueShow] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return [] }
        let words = needle.split(whereSeparator:\.isWhitespace).map(String.init)
        var groups = Array(repeating:[CatalogueShow](),count:4)
        for (position,entry) in entries.enumerated() {
            if position % 128 == 0 { try Task.checkCancellation() }
            if words.allSatisfy({ entry.text.contains($0) }) { groups[entry.rank(needle)].append(entry.show) }
        }
        return groups.flatMap { $0 }
    }
    func merge(_ local: [CatalogueShow], remote: [SearchProviderBatch], query: String) throws -> [CatalogueShow] {
        let needle = Self.normalize(query), words = Self.normalize(query).split(whereSeparator:\.isWhitespace).map(String.init)
        let remoteIDs = Set(remote.flatMap(\.shows).map(\.id))
        var unique = Dictionary(local.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
        for batch in remote { for show in batch.shows { unique[show.id] = show } }
        var prepared = [Entry]()
        for (position,show) in unique.values.enumerated() {
            if position % 128 == 0 { try Task.checkCancellation() }
            let entry = Entry(show)
            // Remote search can offer relevant editorial matches which do not
            // contain every word. Keep those provider-selected results too.
            if words.allSatisfy({ entry.text.contains($0) }) || remoteIDs.contains(show.id) { prepared.append(entry) }
        }
        prepared.sort {
            let a=$0.rank(needle),b=$1.rank(needle)
            return a == b ? $0.show.title.localizedStandardCompare($1.show.title) == .orderedAscending : a < b
        }
        try Task.checkCancellation()
        return prepared.map(\.show)
    }
}

enum ProgrammeSearchRemote {
    private static func batch(_ provider: ContentProvider, fetch: @Sendable () async throws -> [CatalogueShow]) async -> SearchProviderBatch {
        do { return SearchProviderBatch(provider:provider,shows:try await fetch()) }
        catch { return SearchProviderBatch(provider:provider,failed:!Task.isCancelled) }
    }
    static func search(_ query: String) async -> [SearchProviderBatch] {
        async let itv = batch(.itv) { try await ITVCatalogueAPI().search(query) }
        async let channel4 = batch(.channel4) { try await Channel4CatalogueAPI().search(query) }
        async let channel5 = batch(.channel5) { try await Channel5CatalogueAPI().search(query) }
        return await [itv,channel4,channel5]
    }
}

@MainActor final class CatalogueSearchModel: ObservableObject {
    @Published private(set) var state = CatalogueSearchState()
    private struct Cached { let date: Date; let batches: [SearchProviderBatch] }
    private let index: ProgrammeSearchIndex
    private let remote: @Sendable (String) async -> [SearchProviderBatch]
    private let delay: UInt64
    private var generation = UUID()
    private var cache: [String:Cached] = [:]
    private var recent: [String] = []
    init(index: ProgrammeSearchIndex = ProgrammeSearchIndex(),delay: UInt64 = 350_000_000,remote: @escaping @Sendable (String) async -> [SearchProviderBatch] = { query in await ProgrammeSearchRemote.search(query) }) {
        self.index=index;self.delay=delay;self.remote=remote
    }
    func update(_ query: String, source: SearchCatalogueSource) async {
        let id=UUID();generation=id
        let needle=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !needle.isEmpty else { state=CatalogueSearchState();return }
        do {
            try await Task.sleep(nanoseconds:delay)
            try Task.checkCancellation();guard generation==id else { return }
            try await index.prepare(source)
            let local=try await index.matches(needle)
            try Task.checkCancellation();guard generation==id else { return }
            let key=ProgrammeSearchIndex.normalize(needle)
            if let saved=cache[key],Date().timeIntervalSince(saved.date)<300 {
                let result=try await index.merge(local,remote:saved.batches,query:needle)
                try Task.checkCancellation();guard generation==id else { return }
                state=CatalogueSearchState(query:needle,results:result)
                return
            }
            state=CatalogueSearchState(query:needle,results:local,searching:needle.count>=2)
            guard needle.count>=2 else { return }
            let batches=await remote(needle)
            try Task.checkCancellation();guard generation==id else { return }
            let result=try await index.merge(local,remote:batches,query:needle)
            try Task.checkCancellation();guard generation==id else { return }
            let failed=batches.contains(where:\.failed)
            if !failed {
                cache[key]=Cached(date:Date(),batches:batches)
                recent.removeAll { $0==key };recent.append(key)
                while recent.count>12 { cache[recent.removeFirst()]=nil }
            }
            state=CatalogueSearchState(query:needle,results:result,searching:false,error:failed ? "Some search services are unavailable. Showing the results received and local matches." : nil)
        } catch {
            guard generation==id else { return }
            if Task.isCancelled || error is CancellationError { state.searching=false }
            else { state.searching=false;state.error="Search could not finish. Please retry." }
        }
    }
    func cancel() { generation=UUID();state.searching=false }
}
