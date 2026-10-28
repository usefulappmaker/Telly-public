// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

@MainActor final class Library: ObservableObject {
    @Published var saved: [CatalogueShow] = []
    @Published var migrationWarning: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.environment["TELLY_UI_PREVIEW"] == "mixed-saved",
           let data = try? Data(contentsOf: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PreviewSaved.json")),
           let shows = try? JSONDecoder().decode([CatalogueShow].self, from: data) { saved = shows; return }
        #endif
        if let data = defaults.data(forKey: "savedShows-v3"), let shows = try? JSONDecoder().decode([CatalogueShow].self, from: data) { saved = shows }
    }
    func contains(_ show: CatalogueShow) -> Bool { saved.contains { $0.id == show.id } }
    func save(_ show: CatalogueShow) {
        var compact = show; compact.episodes = []; compact.indexedAt = nil
        saved.removeAll { $0.id == show.id }; saved.insert(compact, at: 0)
        persist()
    }
    func remove(_ show: CatalogueShow) { saved.removeAll { $0.id == show.id }; persist() }
    func toggle(_ show: CatalogueShow) { if contains(show) { remove(show) } else { save(show) } }
    func refreshArtwork() async {
        // Refresh only saved programmes when Saved is opened; no episode/catalogue crawl.
        for id in saved.filter({ $0.provider == .bbc }).map(\.id) {
            guard !Task.isCancelled else { return }
            if let fresh = try? await DiscoveryAPI().show(id), !Task.isCancelled,
               let index = saved.firstIndex(where: { $0.id == id }) {
                saved[index].image = fresh.image; persist()
            }
        }
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(saved), forKey: "savedShows-v3") }
    func migrate(resolve: (Programme) async throws -> CatalogueShow = { try await DiscoveryAPI().parent(of: $0) }) async {
        guard let data = defaults.data(forKey: "saved"), let episodes = try? JSONDecoder().decode([Programme].self, from: data) else { return }
        var unresolved = [Programme]()
        for episode in episodes {
            do { let parent = try await resolve(episode); if !contains(parent) { save(parent) } }
            catch { unresolved.append(episode) }
        }
        if unresolved.isEmpty { defaults.removeObject(forKey: "saved"); migrationWarning = nil }
        else { defaults.set(try? JSONEncoder().encode(unresolved), forKey: "saved"); migrationWarning = "\(unresolved.count) older saved episodes could not yet be converted to programmes. They will be retried next time." }
    }
}
